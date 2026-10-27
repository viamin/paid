# frozen_string_literal: true

module ManualReviews
  # Records an authorized, revision-bound reopen-intent decision before any
  # continuation can leave the reopen hold.
  # @spec ISSUE-REOPEN-REVIEW-006
  class RecordReopenDecision
    ACTIONS = %w[retry_analysis resume_implementation collect_evidence].freeze

    class StaleRevisionError < StandardError; end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, action:, reason:, revision:)
      @issue = issue
      @actor = actor
      @action = action.to_s
      @reason = reason.to_s.strip
      @revision = revision.to_s
    end

    def call
      raise ArgumentError, "Select a supported continuation." unless ACTIONS.include?(action)
      raise ArgumentError, "A reopen-review reason is required." if reason.blank?

      issue.with_lock do
        issue.reload
        raise StaleRevisionError, "The issue changed; review the current reopen evidence before deciding." unless current?

        issue.update!(
          reopen_review_decision: action,
          reopen_review_decision_reason: reason,
          reopen_review_decided_at: Time.current,
          reopen_review_decided_by: actor,
          reopen_review_revision: revision
        )
      end
      issue
    end

    private

    attr_reader :action, :actor, :issue, :reason, :revision

    def current?
      issue.reopen_review_pending? && ActiveSupport::SecurityUtils.secure_compare(revision, current_revision)
    end

    def current_revision
      issue.github_updated_at&.iso8601.to_s
    end
  end
end
