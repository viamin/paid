# frozen_string_literal: true

module PostDeployChecks
  module Checks
    # #4812 / CONFIDENCE-DELIVERY-019: once a hold's source issue closes,
    # AgentPlanningHolds::Reconcile#retire_closed_issue resolves its
    # "agent_planning_hold_reconciliation" notification instead of leaving it
    # active. This check counts how many such notifications remain active
    # for the project while their source issue is closed — the live measure
    # of whether that fix is actually in effect, distinct from the 36-case
    # development snapshot recorded when the gap was filed.
    # @spec POST-DEPLOY-CHECK-006 POST-DEPLOY-CHECK-010
    class ClosedAgentPlanningHoldReconciliationCount
      KEY = "closed_agent_planning_hold_reconciliation_count"
      VERSION = 1
      BASELINE = 36
      TARGET = 0
      NOTIFICATION_SOURCE = "agent_planning_hold_reconciliation"

      Result = Data.define(:scope, :active_total, :active_with_closed_source, :baseline, :target) do
        def to_h
          { scope:, active_total:, active_with_closed_source:, baseline:, target: }
        end

        def met_target? = active_with_closed_source <= target
      end

      def self.call(...) = new(...).call

      def initialize(project:)
        @project = project
      end

      def call
        Result.new(
          scope: project.full_name,
          active_total: active_scope.count,
          active_with_closed_source: active_scope.joins(closed_source_issue_join).count,
          baseline: BASELINE,
          target: TARGET
        )
      end

      private

      attr_reader :project

      def active_scope
        Notification.where(account: project.account, source: NOTIFICATION_SOURCE, subject_type: "Issue")
          .active
          .where(subject_id: project.issues.select(:id))
      end

      def closed_source_issue_join
        <<~SQL.squish
          INNER JOIN issues post_deploy_check_source_issues
            ON post_deploy_check_source_issues.id = notifications.subject_id
           AND post_deploy_check_source_issues.github_state = 'closed'
        SQL
      end
    end
  end
end
