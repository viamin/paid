# frozen_string_literal: true

module Activities
  # Scans a project's GitHub repository for open CodeQL code scanning alerts
  # and delegates to the appropriate processors to create/reopen synthetic
  # issues for actionable alerts.
  #
  # Runs after ScanPaidPrsActivity in the GitHubPollWorkflow poll cycle.
  #
  # CodeQL alerts are checked on a configurable interval (default 72h ≈
  # 2-3x/week) and only create issues — they are picked up naturally by
  # AutoPick.
  class ScanSecurityAlertsActivity < BaseActivity
    activity_name "ScanSecurityAlerts"

    SEVERITY_ORDER = Issue::SEVERITY_ORDER

    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { alerts_to_fix: [], project_missing: true } unless project
      return { alerts_to_fix: [] } unless project.auto_scan_security

      severity_filter = severities_at_or_above(project.security_severity_threshold)

      # CodeQL code scanning path (interval-gated)
      scan_code_scanning_alerts(project, severity_filter)

      { alerts_to_fix: [] }
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

    def scan_code_scanning_alerts(project, severity_filter)
      return unless project.security_alert_types.include?("code_scanning")
      return unless should_scan_code_scanning?(project)

      all_alerts = fetch_code_scanning_alerts(project)

      if all_alerts.nil?
        # Graceful 403/404 — record the scan attempt to avoid hammering the
        # API every cycle, but there is nothing else to process.
        project.update_column(:last_code_scanning_scan_at, Time.current)
        return
      end

      SecurityAlerts::ReconcileResolved.new(
        project, all_alerts,
        source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE
      ).call

      filtered = all_alerts.select { |a| severity_filter.include?(a[:severity]) }
      SecurityAlerts::ProcessCodeScanningAlerts.new(project).call(filtered)

      # Record successful scan. Retryable errors (5xx) intentionally skip
      # this so Temporal retries re-check within the same interval window.
      project.update_column(:last_code_scanning_scan_at, Time.current)

      logger.info(
        message: "github_sync.code_scanning_scan_complete",
        project_id: project.id,
        alerts_fetched: all_alerts.size,
        alerts_actionable: filtered.count { |a| a[:state] == "open" }
      )
    end

    def should_scan_code_scanning?(project)
      return true if project.last_code_scanning_scan_at.nil?

      project.last_code_scanning_scan_at <= project.code_scanning_interval_hours.hours.ago
    end

    def fetch_code_scanning_alerts(project)
      client = project.github_token.client
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
        logger.warn(
          message: "github_sync.code_scanning_fetch_failed",
          project_id: project.id,
          error: e.message,
          status: e.status
        )
        nil
      else
        raise
      end
    end

    def severities_at_or_above(threshold)
      idx = SEVERITY_ORDER.index(threshold) || 1
      SEVERITY_ORDER[0..idx]
    end
  end
end
