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
      analysis, contains_merge_commit = verification_evidence(attempt, analyses)
      SecurityAlerts::VerifyRemediationAttempt.new(
        attempt:, alert: alerts[alert_number(attempt.issue)], analysis:, contains_merge_commit:
      ).call
    end

    # GitHub lists analyses newest-first. Evidence must match the finding's
    # configuration and live on the target branch, so a newer PR-branch or
    # unrelated analysis never hides valid evidence; a newer error-bearing
    # analysis falls through to older successful evidence when it exists.
    # A newer entry can also be a rerun of an older main SHA after a valid
    # post-merge analysis has already been uploaded, so we cannot simply take
    # the newest matching successful entry — iterating newest-first lets us
    # prefer the first analysis that actually contains the merge commit and
    # only fall back to closest evidence when none of them does (otherwise
    # the attempt would block on "behind" and `awaiting_attempts` would skip
    # it on subsequent runs, leaving the legitimate evidence unconsidered).
    def verification_evidence(attempt, analyses)
      matching_successful = analyses.select do |analysis|
        relevant?(attempt, analysis) && analysis[:status] == "succeeded"
      end
      containing = matching_successful.find { |analysis| contains_merge_commit?(attempt, analysis) }
      return [ containing, true ] if containing

      fallback_evidence(attempt, analyses)
    end

    def relevant?(attempt, analysis)
      matching_configuration?(attempt, analysis) && analysis[:ref] == project.default_branch
    end

    # No successful target-branch analysis: retain the closest related analysis
    # as blocked-attempt evidence instead of comparing unrelated commits.
    def fallback_evidence(attempt, analyses)
      partial = analyses.find { |analysis| relevant?(attempt, analysis) } ||
                analyses.find { |analysis| matching_configuration?(attempt, analysis) }
      [ partial || analyses.first, false ]
    end

    def contains_merge_commit?(attempt, analysis)
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
