# frozen_string_literal: true

module Inbox
  class MergeApproval
    APPROVAL_SIGNALS = %w[owner_approved reviews_fresh].freeze

    def self.call(issue)
      new(issue).call
    end

    # Narrows to rows that could plausibly be approval-only blockers before
    # falling back to Ruby for the full `call` signal check (`APPROVAL_SIGNALS`),
    # so counting/listing stays a bounded scan instead of one Issue
    # instantiation per open, ready PR on the account. Shared by
    # `Inbox::Count` and `Inbox::Availability` so the candidate definition
    # can't drift between the badge, the filters dialog, and the queue.
    # @spec AUTO-MERGE-009 INBOX-FOUNDATION-008
    def self.candidates(project_ids)
      Issue
        .includes(:project)
        .where(
          project_id: project_ids,
          is_pull_request: true,
          github_state: "open",
          pr_review_phase: "ready",
          merge_permission_rejected_at: nil
        )
        .where.not(projects: { auto_merge_mode: "off" })
        .where(candidate_conditions)
    end

    def self.candidate_conditions
      Issue.sanitize_sql_array([
        "issues.labels @> :hold_label::jsonb OR (" \
          "issues.auto_merge_evaluated_at IS NOT NULL AND " \
          "issues.auto_merge_blockers IS NOT NULL AND " \
          "projects.owner_reviewer_login IS NOT NULL)",
        hold_label: [ Automation::Strategies::AutoMerge::HOLD_FOR_REVIEW_LABEL ].to_json
      ])
    end
    private_class_method :candidate_conditions

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
        return "Human review requested before merging" if held_for_review?
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

      def held_for_review?
        issue.has_label?(Automation::Strategies::AutoMerge::HOLD_FOR_REVIEW_LABEL)
      end
    end

    private

    attr_reader :issue

    def candidate?
      # @spec AUTO-MERGE-009 INBOX-FOUNDATION-008
      return false unless reviewable_pr?
      return true if held_for_review?

      approval_only_blockers?
    end

    def reviewable_pr?
      issue.is_pull_request? &&
        issue.github_state == "open" &&
        issue.pr_review_phase == "ready" &&
        issue.project.auto_merge_enabled? &&
        !issue.merge_permission_rejected?
    end

    def held_for_review?
      issue.has_label?(Automation::Strategies::AutoMerge::HOLD_FOR_REVIEW_LABEL)
    end

    def approval_only_blockers?
      issue.project.owner_reviewer_login.present? &&
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
