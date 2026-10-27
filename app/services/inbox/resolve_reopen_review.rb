# frozen_string_literal: true

module Inbox
  # Records the human validation that permits a reopened issue to be analyzed.
  # The caller owns follow-up run creation so both writes share one transaction.
  # @spec ISSUE-REOPEN-REVIEW-005
  class ResolveReopenReview
    class StaleRevisionError < StandardError; end

    def self.call(...) = new(...).call

    def initialize(issue:, user:, reason:, revision:)
      @issue = issue
      @user = user
      @reason = reason.to_s.strip
      @revision = revision.to_s
    end

    def call
      raise ArgumentError, "A reopen-review decision reason is required." if reason.blank?

      issue.with_lock do
        issue.reload
        raise StaleRevisionError, "The issue changed; review the current evidence before deciding." unless current?
        unless issue.reopen_review_pending?
          raise StaleRevisionError, "This issue is no longer waiting for reopen review."
        end

        AccountActivityEvent.create!(
          account: issue.project.account,
          actor: user,
          subject: issue,
          action: "issue.reopen_review_resolved",
          metadata: { reason:, revision:, reopened_at: issue.reopened_at&.iso8601 }
        )
      end
    end

    private

    attr_reader :issue, :reason, :revision, :user

    def current?
      revision == evidence_revision
    end

    def evidence_revision
      (issue.github_updated_at || issue.updated_at).iso8601
    end
  end
end
