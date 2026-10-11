# frozen_string_literal: true

module Api
  module V1
    # @spec MOBILE-API-006
    # Exceeds the ~100-line class target deliberately: one small payload
    # method per Inbox::Queue::KINDS kind keeps each branch readable, and
    # splitting them into per-kind classes would scatter the `oneOf`
    # dispatch this spec requires across a dozen single-method files.
    class InboxEntrySerializer
      def self.render(entry)
        new(entry).render
      end

      def self.render_list(entry)
        new(entry).render_list
      end

      def initialize(entry)
        @entry = entry
      end

      def render
        common_fields.merge(kind_payload)
      end

      def render_list
        common_fields.merge(list_kind_payload)
      end

      private

      attr_reader :entry

      def common_fields
        {
          id: entry.id,
          kind: entry.kind,
          waiting_since: entry.waiting_since&.iso8601,
          project: project,
          title: entry.title,
          summary: entry.summary,
          action_url: entry.action_url
        }
      end

      def project
        return unless entry.project

        { id: entry.project.id, owner: entry.project.owner, repo: entry.project.repo, name: entry.project.full_name }
      end

      # One branch per Inbox::Queue::KINDS kind, keyed on each entry's actual
      # `record` type rather than the two fields (`questions`/`tasks`) every
      # kind happens to carry on the struct — those are empty for most kinds,
      # so a flat merge was silently dropping the kind-specific detail (e.g.
      # escalated_pr's blocker counters) that only `entry.record` holds.
      def kind_payload
        case entry.kind
        when Inbox::Queue::CLARIFYING_QUESTIONS_KIND then { questions: entry.questions }
        when Inbox::Queue::PLAN_REVIEW_KIND then { tasks: entry.tasks }
        when Inbox::Queue::MERGE_APPROVAL_KIND then merge_approval_payload
        when Inbox::Queue::ACTION_REQUIRED_KIND then { remediation_steps: entry.tasks }
        when Inbox::Queue::ESCALATED_PR_KIND then escalated_pr_payload
        when Inbox::Queue::MANUAL_REVIEW_KIND then manual_review_payload
        when Inbox::Queue::INTENT_CONFORMANCE_KIND then intent_conformance_payload
        when Inbox::Queue::FEATURE_DECISION_KIND then feature_decision_payload
        when Inbox::Queue::RETRY_LIMITED_KIND then retry_limited_payload
        when Inbox::Queue::CHANGE_INTENT_DRAFT_KIND then change_intent_draft_payload
        when Inbox::Queue::PARTIAL_CLOSEOUT_KIND then { unresolved_prerequisites: entry.tasks }
        when Inbox::Queue::TEST_REVIEW_PENDING_KIND then {}
        else
          raise ArgumentError, "Unknown inbox entry kind: #{entry.kind}"
        end
      end

      def list_kind_payload
        return manual_review_list_payload if entry.manual_review?

        kind_payload
      end

      # entry.record is the Issue for merge_approval (not the transient
      # Inbox::MergeApproval::Snapshot), same object the web detail partial
      # reads `auto_merge_blockers` from directly.
      def merge_approval_payload
        { blockers: entry.record.auto_merge_blockers&.fetch("failed", []) || [] }
      end

      # entry.record is Dashboard::BlockedPullRequests::Entry (see
      # app/services/dashboard/blocked_pull_requests.rb) — the reason,
      # tripped counters, last-progress timestamp, and operator-pause state
      # the web detail pane renders.
      def escalated_pr_payload
        blocked = entry.record
        {
          reason: blocked.reason,
          counters: blocked.counters.map { |counter| { name: counter.name, value: counter.value, limit: counter.limit } },
          last_progress_at: blocked.last_progress_at&.iso8601,
          operator_paused: blocked.operator_paused
        }
      end

      def manual_review_payload
        { questions: entry.questions, comment_url: entry.manual_review_comment_url }
      end

      def manual_review_list_payload
        { questions: entry.questions }
      end

      # entry.record is Inbox::IntentConformance::Snapshot, already carrying
      # the verdict and decisions computed when the queue was built.
      def intent_conformance_payload
        snapshot = entry.record
        {
          verdict: intent_conformance_verdict_payload(snapshot.verdict),
          latest_decision: intent_conformance_decision_payload(snapshot.latest_decision)
        }
      end

      def intent_conformance_verdict_payload(verdict)
        return nil unless verdict

        {
          outcome: verdict.outcome,
          reasoning_summary: verdict.reasoning_summary,
          cited_claims: verdict.cited_claims,
          cited_diff_locations: verdict.cited_diff_locations,
          pr_head_sha: verdict.pr_head_sha,
          approved_design_revision: verdict.approved_design_revision
        }
      end

      def intent_conformance_decision_payload(decision)
        return nil unless decision

        { action: decision.action, reason: decision.reason, created_at: decision.created_at&.iso8601 }
      end

      # entry.record is the FeatureIntent itself; readiness is recomputed
      # from its preloaded associations (Inbox::Queue eager-loads
      # feature_intent_decisions/feature_intent_design_prs), so this is a
      # deterministic in-memory check, not an extra query (mirrors the web
      # detail partial's inline call).
      def feature_decision_payload
        readiness = FeatureIntents::ApprovalReadiness.call(feature_intent: entry.record)
        {
          ready: readiness.ready?,
          blockers: readiness.blockers.map { |blocker| { code: blocker.code, message: blocker.message } }
        }
      end

      def retry_limited_payload
        issue = entry.issue
        {
          push_permission_abandoned: issue.push_permission_abandoned?,
          return_count: issue.runner_retry_abandonment_count.to_i - 1
        }
      end

      def change_intent_draft_payload
        change_intent = entry.record
        {
          intent: change_intent.intent,
          behavior: change_intent.behavior,
          constraints: change_intent.constraints,
          decisions_made: change_intent.decisions_made,
          requested_changes_reason: change_intent.requested_changes_reason
        }
      end
    end
  end
end
