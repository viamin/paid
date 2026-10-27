# frozen_string_literal: true

module Issues
  # Records the human's revision-bound reopen decision before releasing the
  # dedicated hold. It deliberately does not queue implementation work.
  # @spec ISSUE-REOPEN-REVIEW-005
  class ResolveReopenReview
    Result = Data.define(:code, :message) do
      def success? = code.nil?
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, reason:, revision:)
      @issue = issue
      @actor = actor
      @reason = reason.to_s.strip
      @revision = revision.to_s
    end

    def call
      return failure(:invalid_reason, "A reopen-review reason is required.") if reason.blank?

      issue.with_lock do
        issue.reload
        return failure(:not_pending, "This issue is no longer awaiting reopen review.") unless issue.reopen_review_pending?
        return failure(:stale_revision, "The issue changed after this review was opened. Refresh and validate the current revision.") unless revision_current?

        issue.update!(
          paid_state: "new", reopen_reviewed_at: Time.current, reopen_reviewed_by: actor,
          reopen_review_decision: "intent_validated", reopen_review_reason: reason,
          reopen_review_revision: issue.github_updated_at
        )
      end
      Audit::RecordEvent.call(action: "issue.reopen_review_resolved", actor: actor, subject: issue,
        metadata: { revision: revision_value, reason: reason })
      Result.new(code: nil, message: "Reopen intent validation recorded. Choose a supported continuation if work remains.")
    end

    private

    attr_reader :actor, :issue, :reason, :revision

    def revision_current?
      revision_value == revision
    end

    def revision_value = issue.github_updated_at&.iso8601(6)

    def failure(code, message) = Result.new(code:, message:)
  end
end
