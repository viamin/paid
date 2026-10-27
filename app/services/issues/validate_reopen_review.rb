# frozen_string_literal: true

module Issues
  # Records an operator's current-intent validation before a reopen may resume.
  # The GitHub revision is an optimistic lock: a changed issue must be reviewed
  # again rather than letting an earlier decision leak forward.
  # @spec ISSUE-REOPEN-REVIEW-005
  class ValidateReopenReview
    Result = Data.define(:success?, :message)

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, reason:, github_revision:)
      @issue = issue
      @actor = actor
      @reason = reason.to_s.strip
      @github_revision = github_revision.to_s
    end

    def call
      return Result.new(false, "A reopen-review reason is required.") if reason.blank?

      issue.with_lock { validate_and_record }
    end

    private

    attr_reader :actor, :github_revision, :issue, :reason

    def validate_and_record
      issue.reload
      return Result.new(false, "This issue is no longer awaiting reopen review.") unless issue.reopen_review_pending?
      return Result.new(false, "The issue changed on GitHub; refresh and validate the current revision.") unless current_revision?

      Audit::RecordEvent.call(
        action: "issue.reopen_review_validated",
        actor: actor,
        subject: issue,
        metadata: { reason: reason, github_revision: github_revision, reopened_at: issue.reopened_at&.iso8601 }
      )
      issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_VALIDATED_REASON)
      Result.new(true, "Reopen review recorded. Select a supported continuation.")
    end

    def current_revision?
      issue.github_updated_at&.iso8601 == github_revision
    end
  end
end
