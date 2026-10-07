# frozen_string_literal: true

module SecurityAlerts
  # Verifies each newly merged remediation against a post-merge scanner analysis,
  # and re-verifies any previously blocked attempt whose evidence has become
  # available (worker restart, repeated poll, repaired credential, next scan).
  # @spec EAGER-QUEUE-013
  # @spec EAGER-QUEUE-014
  class VerifyMergedRemediationAttempts
    def initialize(project:, alerts:, github_client:)
      @project = project
      @alerts = alerts.index_by { |alert| alert[:number] }
      @github_client = github_client
    end

    def call
      analyses = github_client.code_scanning_analyses(project.full_name)
      retryable_attempts.find_each { |attempt| verify(attempt, analyses) }
    end

    private

    attr_reader :project, :alerts, :github_client

    # Both `awaiting_verification` and `verification_blocked` are revisit-able.
    # The verifier applies the same evidence rules EAGER-QUEUE-013 requires for
    # first-time verification, so a re-evaluation is idempotent: a still-blocked
    # attempt keeps its prior status with the latest evidence appended, and a
    # previously blocked attempt that now meets the rules transitions to
    # `verified_fixed` or `verification_failed` (#4152).
    def retryable_attempts
      CodeScanningRemediationAttempt
        .where(issue: code_scanning_issues)
        .retryable_block
    end

    def code_scanning_issues
      project.issues.where(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    end

    def verify(attempt, analyses)
      analysis = matching_analysis(attempt, analyses)
      SecurityAlerts::VerifyRemediationAttempt.new(
        attempt:, alert: alerts[alert_number(attempt.issue)], analysis:,
        contains_merge_commit: merge_commit_in?(attempt, analysis)
      ).call
    end

    def matching_analysis(attempt, analyses)
      analyses.find { |analysis| matching_configuration?(attempt, analysis) } || analyses.first
    end

    def merge_commit_in?(attempt, analysis)
      return false unless analysis && matching_configuration?(attempt, analysis) && analysis[:ref] == project.default_branch

      comparison = github_client.compare(project.full_name, attempt.merge_commit_sha, analysis[:commit_sha])
      comparison.status.in?(%w[ahead identical])
    end

    def matching_configuration?(attempt, analysis)
      analysis[:tool_name] == attempt.tool_name && analysis[:category] == attempt.category
    end

    def alert_number(issue)
      issue.github_issue_id - Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET
    end
  end
end
