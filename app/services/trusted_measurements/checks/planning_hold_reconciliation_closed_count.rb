# frozen_string_literal: true

module TrustedMeasurements
  module Checks
    # Trusted check for #4812's final acceptance: counts active
    # +agent_planning_hold_reconciliation+ notifications whose source issue
    # is closed. A development snapshot recorded 36 such notifications
    # before #4812 shipped; BASELINE records that development-time count for
    # provenance only — it is never inferred as the live result. TARGET is
    # the expected live count once the fix and the reconciliation sweep have
    # both run against the deployed revision: zero.
    #
    # Reports the broader active-notification total for the same source so a
    # zero closed-and-active count is interpretable (no active notifications
    # at all vs. active notifications whose issues are legitimately still
    # open).
    #
    # Read-only: two COUNT queries through normal tenant-scoped
    # ActiveRecord relations. No writes, no cross-tenant join, no raw SQL.
    class PlanningHoldReconciliationClosedCount
      VERSION = 1
      NOTIFICATION_SOURCE = "agent_planning_hold_reconciliation"
      BASELINE = 36
      TARGET = 0

      Result = Data.define(:active_total, :active_closed_issue_count, :baseline, :target, :project_scope) do
        def passing? = active_closed_issue_count == target
      end

      def self.version = VERSION

      def self.call(project:)
        scope = Notification.active
          .where(account_id: project.account_id, source: NOTIFICATION_SOURCE, subject_type: "Issue")
          .where(subject_id: project.issues.select(:id))

        Result.new(
          active_total: scope.count,
          active_closed_issue_count: scope.where(subject_id: project.issues.where(github_state: "closed").select(:id)).count,
          baseline: BASELINE,
          target: TARGET,
          project_scope: "project:#{project.id}:#{project.full_name}"
        )
      end
    end
  end
end
