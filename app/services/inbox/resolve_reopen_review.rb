# frozen_string_literal: true

module Inbox
  # Records the authorization separately from any follow-up run.  This keeps
  # a reopen acknowledgement from silently waiving a changed GitHub revision.
  # @spec ISSUE-REOPEN-REVIEW-005 OPERATOR-INBOX-002L
  class ResolveReopenReview
    Error = Class.new(StandardError)
    DECISIONS = %w[resume_implementation collect_evidence].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(issue:, actor:, decision:, reason:, revision:)
      @issue, @actor, @decision, @reason, @revision = issue, actor, decision, reason, revision
    end

    def call
      validate!
      issue.with_lock do
        issue.reload
        validate_current!
        AccountActivityEvent.create!(account: issue.project.account, actor:, subject: issue,
          action: "issue.reopen_review_resolved",
          metadata: { decision:, reason:, revision: revision, issue_id: issue.id })
        issue.update!(paid_state: "new")
      end
      { notice: "Recorded reopen review decision. #{next_step}" }
    end

    private

    attr_reader :actor, :decision, :issue, :reason, :revision

    def validate!
      raise Error, "Select a supported reopen-review decision." unless DECISIONS.include?(decision)
      raise Error, "A reopen-review reason is required." if reason.to_s.strip.empty?
    end

    def validate_current!
      raise Error, "This issue is no longer waiting for reopen review." unless issue.reopen_review_pending?
      raise Error, "The issue changed; reload it before recording a decision." unless revision == issue.github_updated_at.iso8601
    end

    def next_step
      decision == "collect_evidence" ? "Collect the required validation evidence before implementation." : "The issue may now follow normal admission controls."
    end
  end
end
