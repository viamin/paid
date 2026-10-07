# frozen_string_literal: true

module SecurityAlerts
  # Applies only scanner evidence that is structurally tied to a merged fix.
  # @spec EAGER-QUEUE-013
  class VerifyRemediationAttempt
    def initialize(attempt:, alert:, analysis:, contains_merge_commit:, analysis_missing_reason: nil)
      @attempt = attempt
      @alert = alert
      @analysis = analysis
      @contains_merge_commit = contains_merge_commit
      @analysis_missing_reason = analysis_missing_reason
    end

    def call
      return block!(analysis_missing_reason || "analysis is unavailable") unless analysis
      return block!("analysis did not succeed") unless analysis[:status] == "succeeded"
      return block!("analysis is not on the target branch") unless analysis[:ref] == attempt.issue.project.default_branch
      return block!("analysis configuration differs from the finding") unless matching_configuration?
      return block!("analysis commit does not contain the merge commit") unless contains_merge_commit

      return fail! if alert&.dig(:state) == "open"
      return block!(dismissal_reason) if alert&.dig(:state) == "dismissed"

      resolve!
    end

    private

    attr_reader :attempt, :alert, :analysis, :contains_merge_commit, :analysis_missing_reason

    def matching_configuration?
      analysis[:tool_name] == attempt.tool_name && analysis[:category] == attempt.category
    end

    def evidence
      {
        "pull_request_number" => attempt.pull_request_number,
        "merge_commit_sha" => attempt.merge_commit_sha,
        "analysis_id" => analysis&.dig(:id), "analysis_commit_sha" => analysis&.dig(:commit_sha),
        "analysis_ref" => analysis&.dig(:ref), "alert_number" => alert&.fetch(:number, nil),
        "alert_state" => alert&.dig(:state), "dismissed_reason" => alert&.dig(:dismissed_reason),
        "dismissed_comment" => alert&.dig(:dismissed_comment), "dismissed_by" => alert&.dig(:dismissed_by)
      }.compact
    end

    def dismissal_reason
      reason = alert[:dismissed_reason].presence || "no reason supplied"
      "finding was dismissed upstream: #{reason}"
    end

    def resolve!
      attempt.update!(status: "verified_fixed", verified_at: Time.current, blocked_reason: nil,
        verification_analysis_id: analysis[:id], verification_commit_sha: analysis[:commit_sha],
        verification_ref: analysis[:ref], evidence: attempt.evidence.merge(evidence))
    end

    def fail!
      attempt.update!(status: "verification_failed", verified_at: Time.current,
        blocked_reason: "finding remains open in matching post-merge analysis",
        verification_analysis_id: analysis[:id], verification_commit_sha: analysis[:commit_sha],
        verification_ref: analysis[:ref], evidence: attempt.evidence.merge(evidence))
      attempt.issue.update!(paid_state: "manual_review")
    end

    def block!(reason)
      attempt.update!(status: "verification_blocked", blocked_reason: reason,
        evidence: attempt.evidence.merge(evidence))
    end
  end
end
