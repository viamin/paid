# frozen_string_literal: true

module Issues
  # Records the human decision against the exact reopen event before returning
  # the issue to normal admission.  This is intentionally not an enhancement
  # retry: it records a decision and lets the normal scheduler choose follow-up.
  # @spec ISSUE-REOPEN-REVIEW-005
  class ValidateReopenReview
    Result = Data.define(:success?, :message)

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, reason:)
      @issue = issue
      @actor = actor
      @reason = reason.to_s.strip
    end

    def call
      return Result.new(false, "An intent-validation reason is required.") if reason.blank?

      issue.with_lock do
        issue.reload
        return Result.new(false, "This issue is no longer waiting for reopen review.") unless issue.reopen_review_pending?
        return Result.new(false, "Existing queued or running work must be reconciled before continuing.") if active_work?

        Audit::RecordEvent.call(
          action: "issue.reopen_review_validated",
          actor:,
          subject: issue,
          metadata: { reopened_at: issue.reopened_at&.iso8601, reopen_reason: issue.reopen_reason, reason: }
        )
        issue.update!(paid_state: "new")
      end
      ProcessRunQueueJob.perform_later
      Result.new(true, "Reopen intent validation recorded. Paid will evaluate the issue for supported follow-up work.")
    end

    private

    attr_reader :actor, :issue, :reason

    def active_work?
      issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).exists?
    end
  end
end
