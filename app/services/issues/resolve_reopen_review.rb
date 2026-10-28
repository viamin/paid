# frozen_string_literal: true

module Issues
  class ResolveReopenReview
    Result = Data.define(:status, :message) do
      def success? = status == :resolved
    end

    DECISIONS = %w[valid needs_changes].freeze

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, decision:, reason:, revision:)
      @issue = issue
      @actor = actor
      @decision = decision.to_s
      @reason = reason.to_s.strip
      @revision = revision.to_s
    end

    # @spec ISSUE-REOPEN-REVIEW-005
    def call
      return failure("Choose a reopen-review decision.") unless decision.in?(DECISIONS)
      return failure("A reason is required for the reopen-review decision.") if reason.blank?
      return failure("The reopen-review evidence changed; refresh the Inbox before deciding.") unless revision == current_revision
      return failure("This issue is no longer waiting for reopen review.") unless issue.reopen_review_pending?

      issue.with_lock do
        issue.reload
        return failure("This issue is no longer waiting for reopen review.") unless issue.reopen_review_pending?
        issue.update!(paid_state: "in_progress") if decision == "valid"
        issue.project.account.account_activity_events.create!(
          action: "issue.updated", actor:, subject: issue,
          metadata: { "reopen_review_decision" => decision, "reason" => reason, "revision" => revision }
        )
      end
      Result.new(status: :resolved, message: "Reopen review decision recorded.")
    end

    private

    attr_reader :actor, :decision, :issue, :reason, :revision

    def current_revision
      issue.last_scanned_head_sha.presence || issue.github_updated_at.utc.iso8601
    end

    def failure(message) = Result.new(status: :invalid, message:)
  end
end
