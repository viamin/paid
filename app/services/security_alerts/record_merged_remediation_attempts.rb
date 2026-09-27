# frozen_string_literal: true

module SecurityAlerts
  # Captures GitHub's merge commit before a finding can be re-enqueued.
  # @spec EAGER-QUEUE-013
  class RecordMergedRemediationAttempts
    def initialize(project:, alerts:, github_client:)
      @project = project
      @alerts = alerts.index_by { |alert| alert[:number] }
      @github_client = github_client
    end

    def call
      merged_runs.find_each { |run| record(run) }
    end

    private

    attr_reader :project, :alerts, :github_client

    def merged_runs
      AgentRun.where(project:, goal: "create_pr", issue: code_scanning_issues)
        .where.not(pull_request_number: nil)
        .where.not(id: CodeScanningRemediationAttempt.select(:agent_run_id))
        .joins(<<~SQL.squish)
          INNER JOIN issues merged_remediation_prs
            ON merged_remediation_prs.project_id = agent_runs.project_id
           AND merged_remediation_prs.github_number = agent_runs.pull_request_number
           AND merged_remediation_prs.is_pull_request = TRUE
           AND merged_remediation_prs.pr_review_phase = 'merged'
        SQL
    end

    def code_scanning_issues
      project.issues.where(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    end

    def record(run)
      pull_request = github_client.pull_request(project.full_name, run.pull_request_number)
      merge_sha = pull_request.merge_commit_sha
      return if merge_sha.blank? || pull_request.merged_at.blank?

      issue = run.issue
      alert = alerts[alert_number(issue)] || github_client.code_scanning_alert(project.full_name, alert_number(issue))
      CodeScanningRemediationAttempt.find_or_create_by!(issue:, pull_request_number: run.pull_request_number) do |attempt|
        attempt.assign_attributes(agent_run: run, merge_commit_sha: merge_sha, merged_at: pull_request.merged_at,
          tool_name: alert&.dig(:tool_name), category: alert&.dig(:category),
          evidence: { "pull_request_number" => run.pull_request_number, "merge_commit_sha" => merge_sha })
      end
    end

    def alert_number(issue)
      issue.github_issue_id - Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET
    end
  end
end
