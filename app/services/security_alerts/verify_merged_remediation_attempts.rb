# frozen_string_literal: true

module SecurityAlerts
  # Verifies each newly merged remediation against a post-merge scanner analysis.
  # @spec EAGER-QUEUE-013
  class VerifyMergedRemediationAttempts
    def initialize(project:, alerts:, github_client:)
      @project = project
      @alerts = alerts.index_by { |alert| alert[:number] }
      @github_client = github_client
    end

    def call
      analyses = github_client.code_scanning_analyses(project.full_name)
      awaiting_attempts.find_each { |attempt| verify(attempt, analyses) }
    end

    private

    attr_reader :project, :alerts, :github_client

    def awaiting_attempts
      CodeScanningRemediationAttempt.where(issue: code_scanning_issues, status: "awaiting_verification")
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
    def verification_evidence(attempt, analyses)
      successful = analyses.find { |analysis| relevant?(attempt, analysis) && analysis[:status] == "succeeded" }
      return fallback_evidence(attempt, analyses) unless successful

      [ successful, contains_merge_commit?(attempt, successful) ]
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
