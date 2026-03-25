# frozen_string_literal: true

module SecurityAlerts
  # Raised when a project lacks required configuration for security alert processing
  # (e.g. no trusted GitHub usernames configured).
  class ConfigurationError < StandardError; end

  # Filters actionable Dependabot alerts, creates synthetic issues for new
  # ones, reopens closed issues for re-opened alerts, and updates metadata
  # on existing open issues when the upstream alert payload changes.
  #
  # Returns an array of hashes ({ issue_id:, alert_number:, alert_type: })
  # representing issues that should trigger agent runs.
  #
  # Note: FormatAlert handles title/body generation and ReconcileResolved
  # handles closing stale synthetic issues. If this class grows further,
  # consider extracting CapacityLimiter or IssueCreator collaborators.
  class ProcessAlerts
    SEVERITY_ORDER = Issue::SEVERITY_ORDER
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
        github_updated_at: parse_alert_time(alert[:updated_at]) || Time.current
      )
    end

    def apply_capacity_limit(actionable, reopen_candidates)
      max_runs = @project.max_security_fix_runs
      return [] unless max_runs.to_i.positive?

      combined = actionable.map { |alert| [ :new, alert ] } +
                 reopen_candidates.map { |issue, alert| [ :reopen, issue, alert ] }

      sorted = combined.sort_by do |entry|
        alert = entry[0] == :new ? entry[1] : entry[2]
        SEVERITY_ORDER.index(alert[:severity]) || SEVERITY_ORDER.size
      end

      issues_to_run = []

      sorted.each do |entry|
        break if issues_to_run.size >= max_runs

        if entry[0] == :new
          result = create_issue_for_alert(entry[1])
          issues_to_run << result if result
        else
          issue = entry[1]
          alert = entry[2]
          reopen_closed_issue(issue, alert)
          issues_to_run << { issue_id: issue.id, alert_number: alert[:number], alert_type: "dependabot" }
        end
      end

      issues_to_run
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
        github_created_at: parse_alert_time(alert[:created_at]) || now,
        github_updated_at: parse_alert_time(alert[:updated_at]) || now,
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

      reopen_closed_issue(existing, alert) if existing.github_state != "open"
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

    def reopen_closed_issue(issue, alert)
      issue.update!(
        github_state: "open",
        paid_state: "new",
        github_updated_at: parse_alert_time(alert[:updated_at]) || Time.current
      )
    end

    def parse_alert_time(value)
      return nil if value.nil?

      value.is_a?(String) ? Time.zone.parse(value) : value
    rescue ArgumentError
      nil
    end

    def synthetic_issue_id(alert)
      SYNTHETIC_ISSUE_ID_OFFSET + alert[:number]
    end

    def synthetic_number(alert)
      SYNTHETIC_NUMBER_OFFSET + alert[:number]
    end

    def trusted_login
      @trusted_login ||= begin
        login = @project.allowed_github_usernames
          .filter_map { |u| u.strip.presence }
          .first
        return login if login

        raise SecurityAlerts::ConfigurationError,
          "No trusted GitHub usernames configured for project #{@project.id}"
      end
    end
  end
end
