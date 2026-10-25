# frozen_string_literal: true

module ManualReviews
  # Records the human decision against the GitHub revision the operator saw.
  # AccountActivityEvent is the existing immutable actor/audit surface; this
  # avoids inventing another approval framework for a single recovery gate.
  # @spec ISSUE-REOPEN-REVIEW-005
  class RecordReopenDecision
    DECISIONS = %w[resume_work complete].freeze

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, decision:, reason:, evidence_revision:)
      @issue = issue
      @actor = actor
      @decision = decision
      @reason = reason
      @evidence_revision = evidence_revision
    end

    def call
      validate!
      issue.with_lock do
        issue.reload
        validate!
        issue.update!(paid_state: decision == "complete" ? "completed" : "new")
        AccountActivityEvent.create!(
          account: issue.project.account,
          actor: actor,
          subject: issue,
          action: "issue.reopen_review_decided",
          metadata: { decision: decision, reason: reason, evidence_revision: evidence_revision }
        )
      end
    end

    private

    attr_reader :issue, :actor, :decision, :reason, :evidence_revision

    def validate!
      raise ArgumentError, "This issue is no longer awaiting reopen review." unless issue.reopen_review_pending?
      raise ArgumentError, "Select a reopen-review decision." unless DECISIONS.include?(decision)
      raise ArgumentError, "A reopen-review reason is required." if reason.blank?
      raise ArgumentError, "The issue changed; reopen it again and validate the current revision." unless evidence_revision == issue.github_updated_at&.iso8601
    end
  end
end
