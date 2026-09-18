# frozen_string_literal: true

module Inbox
  # Surfaces a PR blocked by the RDR-067 intent-conformance signal as an
  # actionable Inbox item: the cited claim, the diff locations the reviewer
  # flagged, its reasoning, and the human resolution actions available.
  #
  # Mirrors Inbox::MergeApproval's "read the persisted blocker snapshot,
  # filter to one signal" shape, but the signal is deliberately kept out of
  # Inbox::MergeApproval::APPROVAL_SIGNALS so a material-drift block is never
  # mistaken for an ordinary owner-approval wait (RDR-067 Decision section).
  #
  # @spec INTENT-CONFORMANCE-006
  class IntentConformance
    SIGNAL = "intent_conformance_ok"

    def self.call(issue)
      new(issue).call
    end

    def initialize(issue)
      @issue = issue
    end

    def call
      return unless candidate?

      Snapshot.new(issue: issue, verdict: verdict, decisions: decisions)
    end

    class Snapshot
      attr_reader :issue, :verdict, :decisions

      def initialize(issue:, verdict:, decisions:)
        @issue = issue
        @verdict = verdict
        @decisions = decisions
      end

      def summary
        return "The independent reviewer could not evaluate this pull request against the approved design." if verdict.nil? || verdict.not_evaluated?
        return "Uncertain whether this pull request still matches the approved design." if verdict.uncertain?

        "This pull request changes approved behavior, constraints, scope, or acceptance criteria."
      end

      def waiting_since
        verdict&.evaluated_at || issue.auto_merge_evaluated_at
      end

      def latest_decision
        decisions.max_by(&:created_at)
      end
    end

    private

    attr_reader :issue

    # Read-time guards mirror Inbox::MergeApproval#candidate?: the snapshot is
    # only refreshed while auto-merge runs, so once a project disables
    # auto-merge (or its merge permission is rejected) a stale persisted
    # blocker must not keep this lane alive indefinitely.
    def candidate?
      issue.is_pull_request? &&
        issue.github_state == "open" &&
        issue.pr_review_phase == "ready" &&
        issue.project.auto_merge_enabled? &&
        !issue.merge_permission_rejected? &&
        failed_blocker.present?
    end

    def failed_blocker
      return @failed_blocker if defined?(@failed_blocker)

      @failed_blocker = blockers_snapshot&.fetch("failed", [])&.find { |blocker| blocker["signal"] == SIGNAL }
    end

    def blockers_snapshot
      return @blockers_snapshot if defined?(@blockers_snapshot)

      @blockers_snapshot =
        if issue.auto_merge_evaluated_at.present? && issue.auto_merge_blockers.is_a?(Hash)
          issue.auto_merge_blockers.deep_stringify_keys
        end
    end

    def verdict
      @verdict ||= IntentConformanceVerdict.current_for(issue: issue, head_sha: issue.last_scanned_head_sha)
    end

    def decisions
      @decisions ||= issue.intent_conformance_decisions.where(head_sha: issue.last_scanned_head_sha).to_a
    end
  end
end
