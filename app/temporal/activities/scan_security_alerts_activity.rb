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

    PERMISSION_ERROR_BACKOFF = 1.hour
    UNAVAILABLE_CONFIGURATION_BACKOFF = 1.hour
    TRANSIENT_ERROR_BACKOFF = 5.minutes
    VERIFICATION_INTERVAL = 1.hour
    CODE_SCANNING_NOTIFICATION_SOURCES = [
      Notifications::Rules::CodeScanningVerificationBlocked::SOURCE,
      Notifications::Rules::CodeScanningConfigurationError::SOURCE,
      Notifications::Rules::CodeScanningPermissionsError::SOURCE
    ].freeze

    # @spec AUTOMATION-ACTIVATION-003 GITHUB-SYNC-018
    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { alerts_to_fix: [], project_missing: true } unless project
      unless Automation::FeatureActivation.any_pull_request_feature_enabled?(project:, feature: "auto_scan_security")
        resolve_code_scanning_notifications(project)
        return { alerts_to_fix: [] }
      end

      with_periodic_heartbeat("scan_security_alerts", project_id: project_id) do
        scan_dependabot_alerts(project)
        scan_code_scanning_alerts(project)
      end

      { alerts_to_fix: [] }
    rescue SecurityAlerts::CodeScanningPermissionsError => e
      sync_code_scanning_notifications(project, [])
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "CodeScanningPermissionsError",
        non_retryable: true
      )
    rescue SecurityAlerts::DependabotPermissionsError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "DependabotPermissionsError",
        non_retryable: true
      )
    rescue SecurityAlerts::ConfigurationError => e
      sync_code_scanning_notifications(project, [])
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
      unless project.security_alert_types.include?("code_scanning")
        resolve_code_scanning_notifications(project)
        return
      end
      return unless should_scan_code_scanning?(project)

      heartbeat("scan_security_alerts.fetch_alerts", project_id: project.id)
      project.update_columns(last_code_scanning_scan_attempted_at: Time.current)
      snapshot = fetch_code_scanning_alerts(project)
      all_alerts = snapshot.alerts

      heartbeat("scan_security_alerts.reconcile_resolved", project_id: project.id, alert_count: all_alerts.size)
      SecurityAlerts::ReconcileResolved.new(
        project, snapshot:,
        source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE
      ).call

      open_alerts = all_alerts.select { |a| a[:state] == "open" }
      heartbeat("scan_security_alerts.process_open", project_id: project.id, alert_count: open_alerts.size)
      SecurityAlerts::ProcessCodeScanningAlerts.new(project).call(open_alerts)
      SecurityAlerts::RecordMergedRemediationAttempts.new(
        project:, alerts: open_alerts, github_client: project.client
      ).call
      retryable_attempt_ids = CodeScanningRemediationAttempt
        .where(issue: project.issues.where(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE))
        .retryable_block
        .ids
      SecurityAlerts::VerifyMergedRemediationAttempts.new(
        project:, alerts: all_alerts, github_client: project.client
      ).call

      record_successful_snapshot(project)
      retryable_scope = CodeScanningRemediationAttempt
        .where(id: retryable_attempt_ids)
        .includes(issue: :project)
      sync_code_scanning_notifications(project, retryable_scope)

      logger.info(
        message: "github_sync.code_scanning_scan_complete",
        project_id: project.id,
        alerts_fetched: all_alerts.size,
        alerts_actionable: open_alerts.size
      )
    rescue GithubClient::NotFoundError => e
      record_failure(project, kind: "not_configured", reason: e.message,
        retry_at: UNAVAILABLE_CONFIGURATION_BACKOFF.from_now)
    rescue SecurityAlerts::CodeScanningPermissionsError => e
      record_failure(project, kind: "permission", reason: e.message,
        retry_at: PERMISSION_ERROR_BACKOFF.from_now, permission_error: true)
      raise
    rescue SecurityAlerts::ConfigurationError => e
      record_failure(project, kind: "not_configured", reason: e.message,
        retry_at: UNAVAILABLE_CONFIGURATION_BACKOFF.from_now)
      raise
    rescue GithubClient::RateLimitError => e
      record_failure(project, kind: "rate_limited", reason: e.message,
        retry_at: e.reset_at || TRANSIENT_ERROR_BACKOFF.from_now)
      raise
    rescue GithubClient::Error => e
      record_failure(project, kind: "transient", reason: e.message,
        retry_at: TRANSIENT_ERROR_BACKOFF.from_now)
      raise
    end

    # @spec DEPENDABOT-COVERAGE-001
    def scan_dependabot_alerts(project)
      return unless project.security_alert_types.include?("dependabot")
      return unless should_scan_dependabot?(project)

      heartbeat("scan_security_alerts.fetch_dependabot_alerts", project_id: project.id)
      SecurityAlerts::ProcessDependabotAlerts.new(project).call(fetch_dependabot_alerts(project))
      project.update_columns(
        last_dependabot_scan_at: Time.current,
        dependabot_permission_error_at: nil,
        dependabot_fetch_error_at: nil
      )
    rescue SecurityAlerts::DependabotPermissionsError => e
      # A permission failure blocks the poll cycle on its own (the workflow's
      # `maybe_scan_code_scanning_alerts` treats this as a configuration error
      # and logs/swallows), so let it propagate as an ApplicationError — but
      # only after the visible coverage failure has been published and the
      # one-hour backoff window is armed. # @spec DEPENDABOT-COVERAGE-001
      project.update_columns(dependabot_permission_error_at: Time.current)
      publish_dependabot_ingestion_failure(project, e.message, "permission_denied")
      raise
    rescue GithubClient::Error => e
      # A transient fetch failure (5xx, GraphQL error, etc.) must be a visible
      # coverage failure but MUST NOT starve healthy code-scanning coverage:
      # publish the failure, arm the one-hour fetch-failure backoff, and let
      # scan_code_scanning_alerts proceed. Re-raising here would couple an
      # independent Dependabot outage to the whole poll cycle and skip
      # `last_code_scanning_scan_at` until the Dependabot endpoint recovered.
      # Use dependabot_fetch_error_at (not dependabot_permission_error_at):
      # the two failure classes are diagnosed differently — fetch errors are
      # transient infra and will usually recover without operator action,
      # permission errors are misconfigurations that need a credential or App
      # permission change. Sharing the same column would make the schema
      # ambiguous and prevent operators from telling them apart in the DB.
      # # @spec DEPENDABOT-COVERAGE-001
      project.update_columns(dependabot_fetch_error_at: Time.current)
      publish_dependabot_ingestion_failure(project, e.message, "fetch_failed")
    end

    # Surface retryable verification blockers as blocking inbox notifications
    # and auto-resolve notifications for attempts that have moved to a terminal
    # state on this scan (EAGER-QUEUE-016). Idempotent on (source, subject):
    # Notifications::Publish collapses the metadata merge, and Resolve drops
    # any stale row once the underlying attempt has cleared.
    def sync_code_scanning_notifications(project, retryable_attempts)
      Notifications::Rules::CodeScanningVerificationBlocked.call(scope: retryable_attempts.to_a)
      Notifications::Rules::CodeScanningConfigurationError.call(scope: [ project ])
      Notifications::Rules::CodeScanningPermissionsError.call(scope: [ project ])
    end

    # @spec EAGER-QUEUE-016
    def resolve_code_scanning_notifications(project)
      code_scanning_notifications_for(project).find_each do |notification|
        Notifications::Resolve.call(
          account: project.account,
          source: notification.source,
          subject: notification.subject
        )
      end
    end

    def code_scanning_notifications_for(project)
      Notification.active
        .where(account: project.account, source: CODE_SCANNING_NOTIFICATION_SOURCES)
        .where("metadata ->> 'project_id' = ?", project.id.to_s)
        .includes(:subject)
    end

    def should_scan_code_scanning?(project)
      return false if retry_scheduled?(project)
      return true if project.last_code_scanning_scan_at.nil?
      return true if verification_due?(project)

      project.last_code_scanning_scan_at <= project.code_scanning_interval_hours.hours.ago
    end

    def should_scan_dependabot?(project)
      return false if recent_dependabot_permission_error?(project)
      return false if recent_dependabot_fetch_error?(project)
      return true if project.last_dependabot_scan_at.nil?

      project.last_dependabot_scan_at <= project.code_scanning_interval_hours.hours.ago
    end

    def retry_scheduled?(project)
      project.next_code_scanning_scan_at&.future? || recent_legacy_permission_error?(project)
    end

    def recent_legacy_permission_error?(project)
      project.code_scanning_permission_error_at.present? &&
        project.code_scanning_permission_error_at > PERMISSION_ERROR_BACKOFF.ago
    end

    def recent_dependabot_permission_error?(project)
      project.dependabot_permission_error_at.present? &&
        project.dependabot_permission_error_at > PERMISSION_ERROR_BACKOFF.ago
    end

    def recent_dependabot_fetch_error?(project)
      project.dependabot_fetch_error_at.present? &&
        project.dependabot_fetch_error_at > PERMISSION_ERROR_BACKOFF.ago
    end

    def verification_due?(project)
      awaiting_remediation_verification?(project) &&
        project.last_code_scanning_scan_at <= VERIFICATION_INTERVAL.ago
    end

    def awaiting_remediation_verification?(project)
      CodeScanningRemediationAttempt.joins(:issue)
        .where(issues: { project_id: project.id })
        .retryable_block
        .exists?
    end

    def record_successful_snapshot(project)
      project.update_columns(
        last_code_scanning_scan_at: Time.current,
        code_scanning_permission_error_at: nil,
        code_scanning_scan_error_kind: nil,
        code_scanning_scan_error_reason: nil,
        next_code_scanning_scan_at: nil
      )
    end

    def record_failure(project, kind:, reason:, retry_at:, permission_error: false)
      attributes = {
        code_scanning_scan_error_kind: kind,
        code_scanning_scan_error_reason: AgentRun::ErrorMessageSanitizer.call(text: reason),
        next_code_scanning_scan_at: retry_at
      }
      attributes[:code_scanning_permission_error_at] = Time.current if permission_error
      project.update_columns(attributes)

      logger.warn(
        message: "github_sync.code_scanning_coverage_unavailable",
        project_id: project.id,
        error_kind: kind,
        next_retry_at: retry_at
      )
    end

    def fetch_code_scanning_alerts(project)
      client = project.client
      alerts = client.code_scanning_alerts(project.full_name, default_branch: project.default_branch)
      alerts.concat(%w[fixed dismissed].flat_map do |state|
        client.code_scanning_alert_dispositions(project.full_name, state:)
      end)
      SecurityAlerts::CodeScanningSnapshot.new(repository: project.full_name, branch: project.default_branch,
        configuration_scope: :all, complete: true, alerts:)
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

    def fetch_dependabot_alerts(project)
      project.client.dependabot_alerts(project.full_name)
    rescue GithubClient::ApiError => e
      raise unless e.status == 403

      raise SecurityAlerts::DependabotPermissionsError,
        "GitHub token lacks permission to read Dependabot alerts for #{project.full_name}."
    rescue GithubClient::NotFoundError => e
      raise SecurityAlerts::DependabotPermissionsError,
        "GitHub Dependabot alert ingestion is unavailable for #{project.full_name}: #{e.message}"
    end

    def publish_dependabot_ingestion_failure(project, message, reason)
      Notifications::Publish.call(
        account: project.account, source: "dependabot_alert_coverage_ingestion", subject: project,
        severity: :error, blocking: true, nav_section: "projects",
        title: "Dependabot alert coverage is unavailable", description: message,
        metadata: { project_id: project.id, reason: reason }
      )
    end
  end
end
