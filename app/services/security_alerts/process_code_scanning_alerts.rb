# frozen_string_literal: true

module SecurityAlerts
  # Creates or reopens synthetic issues for open CodeQL code scanning alerts.
  # Code scanning issues are picked up naturally by AutoPick.
  class ProcessCodeScanningAlerts
    SYNTHETIC_SOURCE = Issue::SYNTHETIC_CODE_SCANNING_SOURCE
    SYNTHETIC_ID_OFFSET = Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET
    SYNTHETIC_NUMBER_OFFSET = 200_000_000

    def initialize(project)
      @project = project
    end

    def self.trusted_login_configured?(project)
      trusted_logins(project).any?
    end

    def self.trusted_logins(project)
      Array(project.allowed_github_usernames).filter_map { |username| username.to_s.strip.presence }
    end

    # @param alerts [Array<Hash>] Enriched alert payloads from GithubClient
    # @param excluding_run_id [Integer, nil] Agent run to omit from the prior
    #   attempts history — the run whose prompt refresh triggers processing is
    #   not a prior attempt
    # @spec GITHUB-SYNC-015
    # @spec EAGER-QUEUE-011
    def call(alerts, excluding_run_id: nil)
      open_alerts, resolved_alerts = alerts.partition { |a| a[:state] == "open" }
      close_resolved_issues(resolved_alerts)
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
          reopen_closed_issue(existing, alert, excluding_run_id:)
        else
          update_metadata_if_changed(existing, alert, excluding_run_id:)
        end
      end

      []
    end

    private

    # The periodic scan (Activities::ScanSecurityAlertsActivity) reconciles
    # resolved alerts separately via ReconcileResolved against a full-repo
    # snapshot, and never passes non-open alerts here. This handles the
    # narrower case of a single alert refreshed just before a queued
    # remediation run executes: if it was fixed or dismissed since the run
    # was queued, close the synthetic issue instead of leaving it open for a
    # stale remediation prompt.
    def close_resolved_issues(alerts)
      return if alerts.empty?

      alerts.each do |alert|
        issue = @project.issues.find_by(source: SYNTHETIC_SOURCE,
          github_issue_id: synthetic_issue_id(alert), github_state: "open")
        next unless issue

        issue.update!(github_state: "closed", github_updated_at: Time.current,
          paid_state: "manual_review",
          manual_review_reason: "Upstream code-scanning alert #{alert[:state]}; scanner-verified remediation is not recorded.",
          code_scanning_disposition: alert[:state],
          code_scanning_disposition_reason: alert[:dismissed_reason] || alert[:dismissed_comment],
          code_scanning_disposition_evidence: alert.slice(:number, :state, :dismissed_reason, :dismissed_comment,
            :dismissed_by, :html_url, :updated_at))
      end
    end

    # Every pass over an alert still reported as open is a scanner
    # reconciliation of that alert, whether or not its title/body/labels
    # changed. `default_candidate_source.rb` compares this timestamp against
    # the most recent merged remediation PR to tell a merge that has not yet
    # been re-scanned from a scanner-confirmed still-open (recurrent) alert —
    # a merge alone is never treated as proof the alert is fixed (#4052).
    def stamp_reconciled!(issue)
      issue.update_column(:last_scanner_reconciled_at, Time.current)
    end

    def create_issue_for_alert(alert)
      now = Time.current

      issue = @project.issues.create!(
        github_issue_id: synthetic_issue_id(alert),
        github_number: synthetic_number(alert),
        title: FormatCodeScanningAlert.title(alert),
        body: FormatCodeScanningAlert.body(alert.merge(repository: @project.full_name)),
        github_state: "open",
        github_creator_login: trusted_login,
        github_created_at: parse_alert_time(alert[:created_at]) || now,
        github_updated_at: parse_alert_time(alert[:updated_at]) || now,
        paid_state: "new",
        code_scanning_disposition: "open",
        code_scanning_disposition_evidence: { "number" => alert[:number], "state" => "open" },
        labels: labels_for_alert(alert),
        source: SYNTHETIC_SOURCE
      )
      stamp_reconciled!(issue)
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

    def reopen_closed_issue(issue, alert, excluding_run_id: nil)
      issue.update!(
        title: FormatCodeScanningAlert.title(alert),
        body: formatted_body(issue, alert, excluding_run_id:),
        github_state: "open",
        paid_state: "new",
        code_scanning_disposition: "open",
        code_scanning_disposition_reason: nil,
        code_scanning_disposition_evidence: { "number" => alert[:number], "state" => "open" },
        labels: labels_for_alert(alert),
        github_updated_at: parse_alert_time(alert[:updated_at]) || Time.current
      )
      stamp_reconciled!(issue)
    end

    def update_metadata_if_changed(issue, alert, excluding_run_id: nil)
      new_title = FormatCodeScanningAlert.title(alert)
      new_body = formatted_body(issue, alert, excluding_run_id:)
      new_labels = labels_for_alert(alert)

      # Stamped even when nothing else changed: this pass is itself the
      # scanner's reconfirmation that the alert is still open, which is what
      # lifts a merged-PR guard left over from a prior remediation attempt.
      stamp_reconciled!(issue)
      return if issue.title == new_title && issue.body == new_body && issue.labels == new_labels

      issue.update!(
        title: new_title,
        body: new_body,
        labels: new_labels,
        github_updated_at: parse_alert_time(alert[:updated_at]) || Time.current
      )
    end

    def parse_alert_time(value)
      return nil if value.nil?

      value.is_a?(String) ? Time.zone.parse(value) : value
    rescue ArgumentError
      nil
    end

    def formatted_body(issue, alert, excluding_run_id: nil)
      scope = excluding_run_id ? issue.agent_runs.where.not(id: excluding_run_id) : issue.agent_runs
      FormatCodeScanningAlert.body(
        alert.merge(repository: @project.full_name),
        prior_attempts: scope.order(created_at: :desc).limit(5)
      )
    end

    def synthetic_issue_id(alert)
      SYNTHETIC_ID_OFFSET + alert[:number]
    end

    def synthetic_number(alert)
      SYNTHETIC_NUMBER_OFFSET + alert[:number]
    end

    def trusted_login
      @trusted_login ||= begin
        login = trusted_logins.first
        return login if login

        raise SecurityAlerts::ConfigurationError,
          "No trusted GitHub usernames configured for project #{@project.id}"
      end
    end

    def trusted_logins
      self.class.trusted_logins(@project)
    end

    def labels_for_alert(alert)
      priority = Issue::SEVERITY_TO_PRIORITY[alert[:severity].to_s.downcase]
      %w[security code-scanning].tap { |l| l << @project.priority_label_for(priority) if priority }
    end
  end
end
