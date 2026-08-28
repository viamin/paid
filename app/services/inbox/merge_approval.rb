# frozen_string_literal: true

module Inbox
  class MergeApproval
    APPROVAL_SIGNALS = %w[owner_approved reviews_fresh].freeze

    def self.call(issue)
      new(issue).call
    end

    def initialize(issue)
      @issue = issue
    end

    def call
      return unless candidate?

      Snapshot.new(issue:, blockers: failed_blockers)
    end

    class Snapshot
      attr_reader :blockers, :issue

      def initialize(issue:, blockers:)
        @issue = issue
        @blockers = blockers
      end

      def summary
        return "Waiting for owner re-approval on the current HEAD commit" if stale_approval?

        "Waiting for owner approval"
      end

      def waiting_since
        issue.awaiting_approval_since || issue.github_updated_at
      end

      private

      def stale_approval?
        blockers.any? { |blocker| blocker["signal"] == "reviews_fresh" }
      end
    end

    private

    attr_reader :issue

    def candidate?
      issue.is_pull_request? &&
        issue.github_state == "open" &&
        issue.pr_review_phase == "ready" &&
        issue.project.auto_merge_enabled? &&
        issue.project.owner_reviewer_login.present? &&
        !issue.merge_permission_rejected? &&
        blockers_snapshot.present? &&
        failed_blockers.any? &&
        not_evaluated_blockers.empty? &&
        failed_blockers.all? { |blocker| APPROVAL_SIGNALS.include?(blocker["signal"]) }
    end

    def blockers_snapshot
      return @blockers_snapshot if defined?(@blockers_snapshot)

      @blockers_snapshot =
        if issue.auto_merge_evaluated_at.present? && issue.auto_merge_blockers.is_a?(Hash)
          issue.auto_merge_blockers.deep_stringify_keys
        end
    end

    def failed_blockers
      blockers_snapshot&.fetch("failed", []) || []
    end

    def not_evaluated_blockers
      blockers_snapshot&.fetch("not_evaluated", []) || []
    end
  end
end
