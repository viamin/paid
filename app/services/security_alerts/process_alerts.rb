# frozen_string_literal: true

module SecurityAlerts
  # Filters actionable Dependabot alerts, creates synthetic issues for new
  # ones, reopens closed issues for re-opened alerts, and updates metadata
  # on existing open issues when the upstream alert payload changes.
  #
  # Returns an array of hashes ({ issue_id:, alert_number:, alert_type: })
  # representing issues that should trigger agent runs.
  class ProcessAlerts
    SEVERITY_ORDER = %w[critical high medium low].freeze
    SYNTHETIC_SOURCE = Issue::SYNTHETIC_DEPENDABOT_SOURCE
    SYNTHETIC_ISSUE_ID_OFFSET = Issue::SYNTHETIC_ISSUE_ID_OFFSET
    SYNTHETIC_NUMBER_OFFSET = 100_000_000

    def initialize(project)
      @project = project
    end

    def call(filtered_alerts)
      open_alerts = filtered_alerts.select { |a| a[:state] == "open" }
      return [] if open_alerts.empty?

      actionable, reopen_candidates = filter_actionable(open_alerts)
      apply_capacity_limit(actionable, reopen_candidates)
    end

    private

    def filter_actionable(open_alerts)
      synthetic_ids = open_alerts.map { |a| synthetic_issue_id(a) }
      existing_issues = @project.issues
        .where(source: SYNTHETIC_SOURCE, github_issue_id: synthetic_ids)
        .index_by(&:github_issue_id)

      new_alerts = []
      reopen_candidates = []

      open_alerts.each do |alert|
        existing = existing_issues[synthetic_issue_id(alert)]

        if existing.nil?
          new_alerts << alert
        elsif existing.github_state != "open"
          reopen_candidates << [ existing, alert ]
        else
          update_metadata_if_changed(existing, alert)
        end
      end

      [ new_alerts, reopen_candidates ]
    end

    # Updates an existing open issue's title, body, and timestamp when the
    # upstream Dependabot alert payload has changed (e.g. new patched version,
    # revised severity, updated summary). Does not trigger a new agent run.
    def update_metadata_if_changed(issue, alert)
      new_title = FormatAlert.title(alert)
      new_body = FormatAlert.body(alert)

      return if issue.title == new_title && issue.body == new_body

      issue.update!(
        title: new_title,
        body: new_body,
        github_updated_at: Time.current
      )
    end

    def apply_capacity_limit(actionable, reopen_candidates)
      max_runs = @project.max_security_fix_runs
      sorted_new = sort_by_severity(actionable)
      issues_created = sorted_new.first(max_runs).filter_map do |alert|
        create_issue_for_alert(alert)
      end

      remaining_slots = max_runs - issues_created.size
      if remaining_slots.positive?
        sorted_reopen = sort_by_severity_pair(reopen_candidates)
        sorted_reopen.first(remaining_slots).each do |issue, alert|
          reopen_closed_issue(issue)
          issues_created << { issue_id: issue.id, alert_number: alert[:number], alert_type: "dependabot" }
        end
      end

      issues_created
    end

    def create_issue_for_alert(alert)
      now = Time.current

      issue = @project.issues.create!(
        github_issue_id: synthetic_issue_id(alert),
        github_number: synthetic_number(alert),
        title: FormatAlert.title(alert),
        body: FormatAlert.body(alert),
        github_state: "open",
        github_creator_login: trusted_login,
        github_created_at: now,
        github_updated_at: now,
        paid_state: "new",
        labels: [ "security", "dependabot" ],
        source: SYNTHETIC_SOURCE
      )

      { issue_id: issue.id, alert_number: alert[:number], alert_type: "dependabot" }
    rescue ActiveRecord::RecordNotUnique => e
      Rails.logger.warn(
        message: "github_sync.security_issue_creation_race",
        project_id: @project.id,
        alert_number: alert[:number],
        error: e.message
      )

      existing = @project.issues.find_by(github_issue_id: synthetic_issue_id(alert), source: SYNTHETIC_SOURCE)
      return nil unless existing

      reopen_closed_issue(existing) if existing.github_state != "open"
      { issue_id: existing.id, alert_number: alert[:number], alert_type: "dependabot" }
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        message: "github_sync.security_issue_creation_failed",
        project_id: @project.id,
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

    def synthetic_issue_id(alert)
      SYNTHETIC_ISSUE_ID_OFFSET + alert[:number]
    end

    def synthetic_number(alert)
      SYNTHETIC_NUMBER_OFFSET + alert[:number]
    end

    def sort_by_severity(alerts)
      alerts.sort_by { |a| SEVERITY_ORDER.index(a[:severity]) || SEVERITY_ORDER.size }
    end

    def sort_by_severity_pair(pairs)
      pairs.sort_by { |_issue, alert| SEVERITY_ORDER.index(alert[:severity]) || SEVERITY_ORDER.size }
    end

    def trusted_login
      @trusted_login ||= begin
        login = @project.allowed_github_usernames.find(&:present?)
        return login if login.present?

        raise Temporalio::Error::ApplicationError.new(
          "No trusted GitHub usernames configured for project #{@project.id}",
          type: "ConfigurationError",
          non_retryable: true
        )
      end
    end
  end
end
