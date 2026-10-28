# frozen_string_literal: true

module ManualReviews
  # Persists the human decision before any continuation can leave the gate.
  # @spec ISSUE-REOPEN-REVIEW-005
  class ResolveReopenReview
    Result = Data.define(:success, :error) do
      def success? = success
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, decision:, reason:)
      @issue, @actor, @decision, @reason = issue, actor, decision, reason
    end

    def call
      return Result.new(success: false, error: "A reopen-review reason is required.") if reason.blank?
      return Result.new(success: false, error: "This issue is no longer awaiting reopen review.") unless issue.reopen_review_pending?

      AccountActivityEvent.create!(account: issue.project.account, actor:, subject: issue, action: "issue.updated",
        metadata: { "reopen_review_decision" => decision, "reason" => reason, "revision" => issue.github_updated_at.iso8601 })
      Result.new(success: true, error: nil)
    end

    private

    attr_reader :issue, :actor, :decision, :reason
  end
end
