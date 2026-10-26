# frozen_string_literal: true

module Issues
  # Records an operator's current-intent validation against the GitHub revision
  # displayed in Inbox. A later GitHub update makes that validation stale.
  # @spec ISSUE-REOPEN-REVIEW-005
  class ValidateReopenReview
    Result = Data.define(:success?, :message)

    def self.call(...)
      new(...).call
    end

    def initialize(issue:, actor:, reason:, revision:)
      @issue = issue
      @actor = actor
      @reason = reason.to_s.strip
      @revision = revision.to_s
    end

    def call
      return Result.new(false, "This issue is no longer awaiting reopen review.") unless issue.reopen_review_pending?
      return Result.new(false, "Explain why the reopened issue should resume work.") if reason.blank?
      return Result.new(false, "The issue changed while you were reviewing it. Refresh and validate the current revision.") unless revision == issue.reopen_review_revision

      issue.with_lock { issue.update!(reopen_review_validated_at: Time.current, reopen_review_validated_by: actor, reopen_review_validation_reason: reason, reopen_review_validation_revision: revision) }
      Result.new(true, "Reopen intent recorded. You can now resume implementation.")
    end

    private

    attr_reader :issue, :actor, :reason, :revision
  end
end
