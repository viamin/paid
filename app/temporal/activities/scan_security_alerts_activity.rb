# frozen_string_literal: true

module Activities
  # Scans a project's GitHub repository for open Dependabot security alerts
  # and returns actionable alerts that don't already have associated agent runs.
  #
  # Runs after ScanPaidPrsActivity in the GitHubPollWorkflow poll cycle.
  # Phase 1 covers Dependabot alerts only; code scanning and secret scanning
  # will be added in later phases.
  #
  # Returns a list of alerts that need agent runs to fix them.
  class ScanSecurityAlertsActivity < BaseActivity
    activity_name "ScanSecurityAlerts"

    SEVERITY_ORDER = %w[critical high medium low].freeze
    # Synthetic issues use source "dependabot_alert" so FetchIssuesActivity's
    # stale-close logic (which only targets source "github") won't close them.
    SYNTHETIC_SOURCE = "dependabot_alert"

    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { alerts_to_fix: [], project_missing: true } unless project
      return { alerts_to_fix: [] } unless project.auto_scan_security

      client = project.github_token.client
      alerts = fetch_alerts(project, client)
      reconcile_resolved_alerts(project, alerts)
      actionable = filter_actionable_alerts(project, alerts)

      issues_created = actionable.first(project.max_security_fix_runs).filter_map do |alert|
        create_issue_for_alert(project, alert)
      end

      logger.info(
        message: "security_scanner.scan_complete",
        project_id: project_id,
        alerts_fetched: alerts.size,
        alerts_actionable: actionable.size,
        issues_created: issues_created.size
      )

      { alerts_to_fix: issues_created }
    rescue GithubClient::RateLimitError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "RateLimit",
        non_retryable: false
      )
    end

    private

    def fetch_alerts(project, client)
      alerts = []

      if project.security_alert_types.include?("dependabot")
        severity_filter = severities_at_or_above(project.security_severity_threshold)
        alerts.concat(
          client.dependabot_alerts(project.full_name, severity: severity_filter)
        )
      end

      alerts
    rescue GithubClient::NotFoundError, GithubClient::ApiError => e
      logger.warn(
        message: "security_scanner.fetch_failed",
        project_id: project.id,
        error: e.message
      )
      []
    end

    def filter_actionable_alerts(project, alerts)
      alerts.select do |alert|
        alert[:state] == "open" && !existing_issue_for_alert?(project, alert)
      end
    end

    def existing_issue_for_alert?(project, alert)
      synthetic_id = generate_synthetic_issue_id(alert)
      project.issues
        .where(github_state: "open", source: SYNTHETIC_SOURCE, github_issue_id: synthetic_id)
        .exists?
    end

    def create_issue_for_alert(project, alert)
      title = build_alert_title(alert)
      body = build_alert_body(alert)
      now = Time.current

      issue = project.issues.create!(
        github_issue_id: generate_synthetic_issue_id(alert),
        github_number: generate_synthetic_number(project),
        title: title,
        body: body,
        github_state: "open",
        # Use the project owner as creator so the issue is trusted for prompt building.
        # Dependabot alerts are system-verified, so trust is appropriate here.
        github_creator_login: trusted_login_for(project),
        github_created_at: now,
        github_updated_at: now,
        paid_state: "new",
        labels: [ "security", "dependabot" ],
        source: SYNTHETIC_SOURCE
      )

      { issue_id: issue.id, alert_number: alert[:number], alert_type: "dependabot" }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      logger.warn(
        message: "security_scanner.issue_creation_failed",
        project_id: project.id,
        alert_number: alert[:number],
        error: e.message
      )
      nil
    end

    def build_alert_title(alert)
      parts = [ "[Security]" ]
      parts << "Upgrade #{alert[:package_name]}" if alert[:package_name]
      parts << "to #{alert[:patched_version]}" if alert[:patched_version]
      parts << "(#{alert[:severity]})" if alert[:severity]
      parts << "— #{alert_identifier(alert)}"
      parts.join(" ")
    end

    def build_alert_body(alert)
      lines = []
      lines << "## Dependabot Security Alert ##{alert[:number]}"
      lines << ""
      lines << "**Severity:** #{alert[:severity]}" if alert[:severity]
      lines << "**Package:** #{alert[:package_name]} (#{alert[:package_ecosystem]})" if alert[:package_name]
      lines << "**Patched version:** #{alert[:patched_version]}" if alert[:patched_version]
      lines << "**Summary:** #{alert[:summary]}" if alert[:summary]
      lines << ""
      lines << "### Goal"
      lines << ""

      if alert[:patched_version] && alert[:package_name]
        lines << "Upgrade `#{alert[:package_name]}` to version `#{alert[:patched_version]}` or later"
        lines << "to resolve this security vulnerability. Run the test suite to verify"
        lines << "the upgrade does not introduce regressions."
      else
        lines << "Fix the security vulnerability described above."
      end

      lines << ""
      lines << "[View alert on GitHub](#{alert[:html_url]})" if alert[:html_url]
      lines.join("\n")
    end

    # Close synthetic issues whose Dependabot alerts are no longer open
    # (fixed, dismissed, or auto_dismissed upstream).
    def reconcile_resolved_alerts(project, current_open_alerts)
      open_alert_ids = current_open_alerts
        .select { |a| a[:state] == "open" }
        .map { |a| generate_synthetic_issue_id(a) }
        .to_set

      stale_scope = project.issues.where(github_state: "open", source: SYNTHETIC_SOURCE)
      stale_scope = stale_scope.where.not(github_issue_id: open_alert_ids) if open_alert_ids.any?
      count = stale_scope.count

      if count > 0
        stale_scope.update_all(github_state: "closed", paid_state: "resolved", updated_at: Time.current)
        logger.info(
          message: "security_scanner.reconciled_resolved_alerts",
          project_id: project.id,
          closed_count: count
        )
      end
    end

    def alert_identifier(alert)
      "dependabot-alert-#{alert[:number]}"
    end

    def generate_synthetic_issue_id(alert)
      # Use a large offset to avoid collisions with real GitHub issue IDs.
      # Dependabot alert numbers are scoped per-repo and are small integers.
      9_000_000_000 + alert[:number]
    end

    def generate_synthetic_number(project)
      # Use a large offset (900_000) to avoid collisions with real GitHub
      # issue/PR numbers, which are sequential small integers.
      max_number = project.issues.maximum(:github_number) || 0
      [ max_number + 1, 900_000 ].max
    end

    def severities_at_or_above(threshold)
      idx = SEVERITY_ORDER.index(threshold) || 1
      SEVERITY_ORDER[0..idx]
    end

    # Returns the first allowed username for the project, so synthetic issues
    # are trusted and their body can be used as the agent prompt.
    def trusted_login_for(project)
      project.allowed_github_usernames.first || "paid[bot]"
    end
  end
end
