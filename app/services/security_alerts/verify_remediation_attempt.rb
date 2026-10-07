# frozen_string_literal: true

module SecurityAlerts
  # Applies only scanner evidence that is structurally tied to a merged fix.
  # @spec EAGER-QUEUE-013
  # @spec EAGER-QUEUE-014
  class VerifyRemediationAttempt
    def initialize(attempt:, alert:, analysis:, contains_merge_commit:)
      @attempt = attempt
      @alert = alert
      @analysis = analysis
      @contains_merge_commit = contains_merge_commit
    end

    def call
      return block!("analysis is unavailable") unless analysis
      return block!("analysis evidence is malformed") if analysis[:status] == "malformed"
      return block!("analysis is not on the target branch") unless analysis[:ref] == attempt.issue.project.default_branch
      return block!("analysis configuration differs from the finding") unless matching_configuration?
      return block!(failure_reason) unless analysis[:status] == "succeeded"
      return block!("analysis commit does not contain the merge commit") unless contains_merge_commit

      return resolve! unless alert

      fail!
    end

    private

    attr_reader :attempt, :alert, :analysis, :contains_merge_commit

    def failure_reason
      detail = analysis[:error].to_s
      detail.empty? ? "analysis did not succeed" : "analysis did not succeed: #{detail}"
    end

    def matching_configuration?
      analysis[:tool_name] == attempt.tool_name && analysis[:category] == attempt.category
    end

    def evidence
      {
        "pull_request_number" => attempt.pull_request_number,
        "merge_commit_sha" => attempt.merge_commit_sha,
        "analysis_id" => analysis&.dig(:id), "analysis_commit_sha" => analysis&.dig(:commit_sha),
        "analysis_ref" => analysis&.dig(:ref), "alert_number" => alert&.fetch(:number, nil),
        "analysis_error" => analysis&.dig(:error).presence, "analysis_warning" => analysis&.dig(:warning).presence
      }.compact
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
      move_issue_to_manual_review
    end

    # A retryable block — the verifier still cannot prove the fix worked, but
    # the attempt is not terminal: it keeps its prior status and appends the
    # latest evidence. Without this idempotency, a worker restart or repeated
    # poll would silently strand the attempt forever (#4152). On the first
    # transition from `awaiting_verification`, status moves to
    # `verification_blocked`; on a re-verification of an already-blocked
    # attempt, status is preserved and only the evidence + reason advance.
    def block!(reason)
      attrs = { blocked_reason: reason, evidence: attempt.evidence.merge(evidence) }
      attrs[:status] = "verification_blocked" unless attempt.status == "verification_blocked"
      attempt.update!(attrs)
    end

    # Only move to manual_review on the FIRST scanner-confirmed unsuccessful
    # fix (EAGER-QUEUE-014). A subsequent re-verification that re-confirms the
    # finding is already-open leaves the issue where it was — moving it would
    # override any operator annotations on `manual_review_reason` since the
    # earlier transition.
    def move_issue_to_manual_review
      issue = attempt.issue
      return if issue.paid_state == "manual_review"

      issue.update!(paid_state: "manual_review")
    end
  end
end
