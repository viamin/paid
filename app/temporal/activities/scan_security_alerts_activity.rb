# frozen_string_literal: true

module Activities
  # Scans a project's GitHub repository for open Dependabot security alerts
  # and delegates to SecurityAlerts::ProcessAlerts to create/reopen synthetic
  # issues for actionable alerts.
  #
  # Runs after ScanPaidPrsActivity in the GitHubPollWorkflow poll cycle.
  # Phase 1 covers Dependabot alerts only; code scanning and secret scanning
  # will be added in later phases.
  #
  # Returns a list of issues that were created or reopened to fix outstanding alerts.
  class ScanSecurityAlertsActivity < BaseActivity
    activity_name "ScanSecurityAlerts"

    SEVERITY_ORDER = Issue::SEVERITY_ORDER

    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { alerts_to_fix: [], project_missing: true } unless project
      return { alerts_to_fix: [] } unless project.auto_scan_security

      client = project.github_token.client
      all_alerts = fetch_alerts(project, client)
      SecurityAlerts::ReconcileResolved.new(project, all_alerts).call unless all_alerts.nil?

      severity_filter = severities_at_or_above(project.security_severity_threshold)
      filtered_alerts = (all_alerts || []).select { |a| severity_filter.include?(a[:severity]) }
      issues_created = SecurityAlerts::ProcessAlerts.new(project).call(filtered_alerts)

      logger.info(
        message: "github_sync.security_scan_complete",
        project_id: project_id,
        alerts_fetched: all_alerts&.size,
        alerts_fetch_skipped: all_alerts.nil?,
        alerts_actionable: filtered_alerts.count { |a| a[:state] == "open" },
        issues_created: issues_created.size
      )

      { alerts_to_fix: issues_created }
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

    def fetch_alerts(project, client)
      return nil if project.security_alert_types.empty?
      return nil unless project.security_alert_types.include?("dependabot")

      client.dependabot_alerts(project.full_name)
    rescue GithubClient::NotFoundError => e
      logger.warn(
        message: "github_sync.security_fetch_failed",
        project_id: project.id,
        error: e.message
      )
      nil
    rescue GithubClient::ApiError => e
      if e.status == 403
        logger.warn(
          message: "github_sync.security_fetch_failed",
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
