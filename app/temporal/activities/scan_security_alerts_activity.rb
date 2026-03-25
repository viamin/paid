# frozen_string_literal: true

module Activities
  # Scans a project's GitHub repository for open Dependabot security alerts
  # and identifies alerts that should have synthetic issues created or existing
  # issues reopened, subject to severity and capacity limits.
  #
  # Runs after ScanPaidPrsActivity in the GitHubPollWorkflow poll cycle.
  # Phase 1 covers Dependabot alerts only; code scanning and secret scanning
  # will be added in later phases.
  #
  # Returns a list of issues that were created or reopened to fix outstanding alerts.
  class ScanSecurityAlertsActivity < BaseActivity
    activity_name "ScanSecurityAlerts"

    SEVERITY_ORDER = %w[critical high medium low].freeze
    # Canonical constants live in Issue to avoid coupling the model to this
    # activity class. Local aliases keep activity code concise.
    SYNTHETIC_SOURCE = Issue::SYNTHETIC_DEPENDABOT_SOURCE
    SYNTHETIC_ISSUE_ID_OFFSET = Issue::SYNTHETIC_ISSUE_ID_OFFSET
    # Offset for synthetic github_number values (integer column, max ~2.1B).
    # GitHub issue/PR numbers are sequential; even the busiest repos rarely
    # exceed a few hundred thousand, so 100M provides ample headroom.
    SYNTHETIC_NUMBER_OFFSET = 100_000_000

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
      actionable, reopen_candidates = filter_actionable_alerts(project, filtered_alerts)

      issues_created = apply_capacity_limit(project, actionable, reopen_candidates)

      logger.info(
        message: "github_sync.security_scan_complete",
        project_id: project_id,
        alerts_fetched: all_alerts&.size,
        alerts_fetch_skipped: all_alerts.nil?,
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

    def filter_actionable_alerts(project, alerts)
      open_alerts = alerts.select { |a| a[:state] == "open" }
      return [ [], [] ] if open_alerts.empty?

      synthetic_ids = open_alerts.map { |a| generate_synthetic_issue_id(a) }
      existing_issues = project.issues
        .where(source: SYNTHETIC_SOURCE, github_issue_id: synthetic_ids)
        .index_by(&:github_issue_id)

      new_alerts = []
      reopen_candidates = []

      open_alerts.each do |alert|
        existing = existing_issues[generate_synthetic_issue_id(alert)]

        if existing.nil?
          new_alerts << alert
        elsif existing.github_state != "open"
          reopen_candidates << [ existing, alert ]
        end
      end

      [ new_alerts, reopen_candidates ]
    end

    def apply_capacity_limit(project, actionable, reopen_candidates)
      max_runs = project.max_security_fix_runs
      issues_created = actionable.first(max_runs).filter_map do |alert|
        create_issue_for_alert(project, alert)
      end

      remaining_slots = max_runs - issues_created.size
      if remaining_slots.positive?
        reopen_candidates.first(remaining_slots).each do |issue, alert|
          reopen_closed_issue(issue)
          issues_created << { issue_id: issue.id, alert_number: alert[:number], alert_type: "dependabot" }
        end
      end

      issues_created
    end

    def create_issue_for_alert(project, alert)
      now = Time.current

      issue = project.issues.create!(
        github_issue_id: generate_synthetic_issue_id(alert),
        github_number: generate_synthetic_number(alert),
        title: SecurityAlerts::FormatAlert.title(alert),
        body: SecurityAlerts::FormatAlert.body(alert),
        github_state: "open",
        github_creator_login: trusted_login_for(project),
        github_created_at: now,
        github_updated_at: now,
        paid_state: "new",
        labels: [ "security", "dependabot" ],
        source: SYNTHETIC_SOURCE
      )

      { issue_id: issue.id, alert_number: alert[:number], alert_type: "dependabot" }
    rescue ActiveRecord::RecordNotUnique => e
      logger.warn(
        message: "github_sync.security_issue_creation_race",
        project_id: project.id,
        alert_number: alert[:number],
        error: e.message
      )

      existing = project.issues.find_by(github_issue_id: generate_synthetic_issue_id(alert), source: SYNTHETIC_SOURCE)
      return nil unless existing

      reopen_closed_issue(existing) if existing.github_state != "open"
      { issue_id: existing.id, alert_number: alert[:number], alert_type: "dependabot" }
    rescue ActiveRecord::RecordInvalid => e
      logger.warn(
        message: "github_sync.security_issue_creation_failed",
        project_id: project.id,
        alert_number: alert[:number],
        error: e.message
      )
      nil
    end

    def reopen_closed_issue(issue)
      issue.update!(
        github_state: "open",
        paid_state: "new",
        github_updated_at: Time.current
      )
    end

    def generate_synthetic_issue_id(alert)
      SYNTHETIC_ISSUE_ID_OFFSET + alert[:number]
    end

    def generate_synthetic_number(alert)
      SYNTHETIC_NUMBER_OFFSET + alert[:number]
    end

    def severities_at_or_above(threshold)
      idx = SEVERITY_ORDER.index(threshold) || 1
      SEVERITY_ORDER[0..idx]
    end

    def trusted_login_for(project)
      login = project.allowed_github_usernames.find(&:present?)
      return login if login.present?

      raise Temporalio::Error::ApplicationError.new(
        "No trusted GitHub usernames configured for project #{project.id}",
        type: "ConfigurationError",
        non_retryable: true
      )
    end
  end
end
