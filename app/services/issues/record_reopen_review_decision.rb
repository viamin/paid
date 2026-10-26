# frozen_string_literal: true

require "digest"

module Issues
  # Persists an authorized operator's decision against the exact reopen-review
  # evidence currently visible in the Inbox.
  # @spec ISSUE-REOPEN-REVIEW-005
  class RecordReopenReviewDecision
    DECISIONS = %w[continue no_further_work].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(issue:, actor:, decision:, reason:)
      @issue = issue
      @actor = actor
      @decision = decision
      @reason = reason.to_s.strip
    end

    def call
      validate!
      issue.with_lock do
        issue.reload
        validate_pending!
        issue.update!(
          reopen_review_validated_at: Time.current,
          reopen_review_validated_by: actor,
          reopen_review_decision: decision,
          reopen_review_reason: reason,
          reopen_review_validation_digest: issue.reopen_review_evidence_digest
        )
      end
    end

    private

    attr_reader :issue, :actor, :decision, :reason

    def validate!
      raise ArgumentError, "Select a reopen-review decision." unless decision.in?(DECISIONS)
      raise ArgumentError, "Provide a reason for the reopen-review decision." if reason.blank?
    end

    def validate_pending!
      raise ArgumentError, "This issue is no longer waiting for reopen review." unless issue.reopen_review_pending?
    end
  end
end
