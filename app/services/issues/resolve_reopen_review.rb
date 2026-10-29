# frozen_string_literal: true

module Issues
  # Records an authorized, revision-bound decision before reopening delivery.
  # @spec ISSUE-REOPEN-REVIEW-005
  class ResolveReopenReview
    Result = Data.define(:status, :message) do
      def success? = status == :resolved
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, reason:, revision:)
      @issue = issue
      @actor = actor
      @reason = reason.to_s.strip
      @revision = revision.to_s
    end

    def call
      return Result.new(status: :invalid, message: "This issue is no longer waiting for reopen review.") unless issue.reopen_review_pending?
      return Result.new(status: :invalid, message: "Explain why the reopened issue should resume.") if reason.blank?
      return Result.new(status: :stale, message: "The issue changed after this review opened. Refresh and validate the current revision.") unless current_revision?
      return Result.new(status: :active_work, message: "An existing run must be reconciled before this reopen review can resume work.") if active_run?

      Issue.transaction do
        issue.lock!
        return Result.new(status: :invalid, message: "This issue is no longer waiting for reopen review.") unless issue.reopen_review_pending?
        return Result.new(status: :stale, message: "The issue changed after this review opened. Refresh and validate the current revision.") unless current_revision?
        return Result.new(status: :active_work, message: "An existing run must be reconciled before this reopen review can resume work.") if active_run?

        AccountActivityEvent.create!(
          account: issue.project.account, actor:, subject: issue, action: "issue.updated",
          metadata: { "reopen_review" => "resume_work", "reason" => reason, "revision" => revision }
        )
        issue.update!(paid_state: "new")
      end

      Result.new(status: :resolved, message: "Reopen review recorded. Paid will evaluate the current issue for supported continuation.")
    end

    private

    attr_reader :actor, :issue, :reason, :revision

    def current_revision?
      revision.present? && revision == issue.github_updated_at&.iso8601
    end

    def active_run?
      issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).exists?
    end
  end
end
