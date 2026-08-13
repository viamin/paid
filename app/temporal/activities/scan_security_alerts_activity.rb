# frozen_string_literal: true

module Activities
  # Scans a project's GitHub repository for open CodeQL code scanning alerts
  # and delegates to the appropriate processors to create/reopen synthetic
  # issues for actionable alerts.
  #
  # Runs after ScanPaidPrsActivity in the GitHubPollWorkflow poll cycle.
  #
  # CodeQL alerts are checked on a configurable interval (default 24h) and
  # only create issues — they are picked up naturally by
  # AutoPick.
  class ScanSecurityAlertsActivity < BaseActivity
    activity_name "ScanSecurityAlerts"

    # Backoff for a confirmed permission/configuration error (403 -- missing
    # security_events / code_scanning_alerts:read). Deliberately much shorter
    # than code_scanning_interval_hours: a stale credential is retried every
    # poll cycle otherwise (every 1-2 minutes in some environments), which
    # wastes worker capacity and API quota on a call that will fail
    # identically until a human fixes the token/App permission. An hour still
    # picks up a fix promptly without the full-interval "stale blackout" the
    # original no-backoff design was written to avoid.
    PERMISSION_ERROR_BACKOFF = 1.hour

    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { alerts_to_fix: [], project_missing: true } unless project
      return { alerts_to_fix: [] } unless project.auto_scan_security

      with_periodic_heartbeat("scan_security_alerts", project_id: project_id) do
        scan_code_scanning_alerts(project)
      end

      { alerts_to_fix: [] }
    rescue SecurityAlerts::CodeScanningPermissionsError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "CodeScanningPermissionsError",
        non_retryable: true
      )
    rescue SecurityAlerts::ConfigurationError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "ConfigurationError",
        non_retryable: true
      )
    rescue GithubClient::RateLimitError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "RateLimit",
        non_retryable: false
      )
    end

    private

    def scan_code_scanning_alerts(project)
      return unless project.security_alert_types.include?("code_scanning")
      return unless should_scan_code_scanning?(project)

      heartbeat("scan_security_alerts.fetch_alerts", project_id: project.id)
      all_alerts = fetch_code_scanning_alerts(project)

      if all_alerts.nil?
        project.update_columns(last_code_scanning_scan_at: Time.current, code_scanning_permission_error_at: nil)
        return
      end

      heartbeat("scan_security_alerts.reconcile_resolved", project_id: project.id, alert_count: all_alerts.size)
      SecurityAlerts::ReconcileResolved.new(
        project, all_alerts,
        source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE
      ).call

      open_alerts = all_alerts.select { |a| a[:state] == "open" }
      heartbeat("scan_security_alerts.process_open", project_id: project.id, alert_count: open_alerts.size)
      SecurityAlerts::ProcessCodeScanningAlerts.new(project).call(open_alerts)

      # Record scan timestamp only after successful processing. Retryable
      # errors (5xx) intentionally skip this so Temporal retries within the
      # same interval window.
      project.update_columns(last_code_scanning_scan_at: Time.current, code_scanning_permission_error_at: nil)

      logger.info(
        message: "github_sync.code_scanning_scan_complete",
        project_id: project.id,
        alerts_fetched: all_alerts.size,
        alerts_actionable: open_alerts.size
      )
    rescue SecurityAlerts::CodeScanningPermissionsError
      # Do NOT advance last_code_scanning_scan_at here. A 403 means the token
      # lacks the required scope — advancing the timestamp would suppress
      # retries for the full code_scanning_interval_hours window, turning a
      # recoverable misconfiguration into a stale blackout. Instead, record
      # code_scanning_permission_error_at so should_scan_code_scanning? backs
      # off for PERMISSION_ERROR_BACKOFF (much shorter than the full
      # interval) instead of retrying every poll cycle. The workflow also
      # catches ConfigurationError and logs a warning.
      project.update_column(:code_scanning_permission_error_at, Time.current)
      raise
    end

    def should_scan_code_scanning?(project)
      return false if recent_permission_error?(project)
      return true if project.last_code_scanning_scan_at.nil?

      project.last_code_scanning_scan_at <= project.code_scanning_interval_hours.hours.ago
    end

    def recent_permission_error?(project)
      project.code_scanning_permission_error_at.present? &&
        project.code_scanning_permission_error_at > PERMISSION_ERROR_BACKOFF.ago
    end

    def fetch_code_scanning_alerts(project)
      client = project.client
      client.code_scanning_alerts(project.full_name)
    rescue GithubClient::NotFoundError => e
      logger.warn(
        message: "github_sync.code_scanning_fetch_failed",
        project_id: project.id,
        error: e.message
      )
      nil
    rescue GithubClient::ApiError => e
      if e.status == 403
        raise SecurityAlerts::CodeScanningPermissionsError,
          "GitHub token lacks permission to read code scanning alerts for #{project.full_name}. " \
          "Ensure the token includes the security_events scope (classic PAT) or " \
          "code_scanning_alerts:read permission (fine-grained PAT)."
      else
        raise
      end
    end
  end
end
