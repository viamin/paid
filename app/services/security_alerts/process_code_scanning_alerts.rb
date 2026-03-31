# frozen_string_literal: true

module SecurityAlerts
  # Creates or reopens synthetic issues for open CodeQL code scanning alerts.
  # Unlike ProcessAlerts (Dependabot), this service does NOT return
  # alerts_to_fix — code scanning issues are picked up naturally by AutoPick.
  class ProcessCodeScanningAlerts
    SYNTHETIC_SOURCE = Issue::SYNTHETIC_CODE_SCANNING_SOURCE
    SYNTHETIC_ID_OFFSET = Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET
    SYNTHETIC_NUMBER_OFFSET = 200_000_000

    def initialize(project)
      @project = project
    end

    def call(filtered_alerts)
      open_alerts = filtered_alerts.select { |a| a[:state] == "open" }
      return [] if open_alerts.empty?

      synthetic_ids = open_alerts.map { |a| synthetic_issue_id(a) }
      existing_issues = @project.issues
        .where(source: SYNTHETIC_SOURCE, github_issue_id: synthetic_ids)
        .index_by(&:github_issue_id)

      open_alerts.each do |alert|
        existing = existing_issues[synthetic_issue_id(alert)]

        if existing.nil?
          create_issue_for_alert(alert)
        elsif existing.github_state != "open"
          reopen_closed_issue(existing, alert)
        else
          update_metadata_if_changed(existing, alert)
        end
      end

      []
    end

    private

    def create_issue_for_alert(alert)
      now = Time.current

      @project.issues.create!(
        github_issue_id: synthetic_issue_id(alert),
        github_number: synthetic_number(alert),
        title: FormatCodeScanningAlert.title(alert),
        body: FormatCodeScanningAlert.body(alert),
        github_state: "open",
        github_creator_login: trusted_login,
        github_created_at: parse_alert_time(alert[:created_at]) || now,
        github_updated_at: parse_alert_time(alert[:updated_at]) || now,
        paid_state: "new",
        labels: %w[security code-scanning],
        source: SYNTHETIC_SOURCE
      )
    rescue ActiveRecord::RecordNotUnique => e
      Rails.logger.warn(
        message: "github_sync.code_scanning_issue_creation_race",
        project_id: @project.id,
        alert_number: alert[:number],
        error: e.message
      )

      existing = @project.issues.find_by(github_issue_id: synthetic_issue_id(alert), source: SYNTHETIC_SOURCE)
      reopen_closed_issue(existing, alert) if existing && existing.github_state != "open"
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        message: "github_sync.code_scanning_issue_creation_failed",
        project_id: @project.id,
        alert_number: alert[:number],
        error: e.message
      )
    end

    def reopen_closed_issue(issue, alert)
      issue.update!(
        title: FormatCodeScanningAlert.title(alert),
        body: FormatCodeScanningAlert.body(alert),
        github_state: "open",
        paid_state: "new",
        github_updated_at: parse_alert_time(alert[:updated_at]) || Time.current
      )
    end

    def update_metadata_if_changed(issue, alert)
      new_title = FormatCodeScanningAlert.title(alert)
      new_body = FormatCodeScanningAlert.body(alert)

      return if issue.title == new_title && issue.body == new_body

      issue.update!(
        title: new_title,
        body: new_body,
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
      SYNTHETIC_ID_OFFSET + alert[:number]
    end

    def synthetic_number(alert)
      SYNTHETIC_NUMBER_OFFSET + alert[:number]
    end

    def trusted_login
      @trusted_login ||= begin
        login = Array(@project.allowed_github_usernames)
          .filter_map { |u| u.to_s.strip.presence }
          .first
        return login if login

        raise SecurityAlerts::ConfigurationError,
          "No trusted GitHub usernames configured for project #{@project.id}"
      end
    end
  end
end
