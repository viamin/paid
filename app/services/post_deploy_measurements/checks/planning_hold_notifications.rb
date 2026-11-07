# frozen_string_literal: true

module PostDeployMeasurements
  module Checks
    # The trusted #4812 check: after the fix deploys, none of the closed
    # planning-hold requests may remain actionable in the live Inbox. Counts
    # active `agent_planning_hold_reconciliation` notifications whose subject
    # issue is closed — resolving AgentRun subjects through their issue —
    # inside one account and one project scope, and reports the surrounding
    # totals and scope so a zero is interpretable. A development snapshot or
    # a merged PR is never the measured result.
    # @spec POST-DEPLOY-002
    class PlanningHoldNotifications
      NOTIFICATION_SOURCE = "agent_planning_hold_reconciliation"

      CHECK = PostDeployMeasurements::Check.new(
        key: "planning_hold_notifications_actionable",
        version: 1,
        criterion: "No active agent_planning_hold_reconciliation notification whose source issue is " \
                   "closed remains actionable after the deployment (#4812).",
        baseline: 36,
        target: 0,
        capabilities: %w[notifications].freeze,
        measurer: PlanningHoldNotifications
      ).freeze

      Result = Data.define(:counts, :scope) do
        def actionable_count = counts.fetch("actionable_closed_source")
      end

      def self.measure(project:)
        base = Notification.active.where(account: project.account, source: NOTIFICATION_SOURCE)
        subject_scope = subject_issue_scope(project)

        Result.new(
          counts: {
            "actionable_closed_source" => base.merge(subject_scope).merge(closed_source).count,
            "active_open_source" => base.merge(subject_scope).merge(open_source).count,
            "active_total" => base.merge(subject_scope).count,
            "resolved_total" => Notification.where.not(resolved_at: nil)
              .where(account: project.account, source: NOTIFICATION_SOURCE).merge(subject_scope).count
          },
          scope: {
            "account_id" => project.account_id,
            "project_id" => project.id,
            "project" => project.full_name,
            "notification_source" => NOTIFICATION_SOURCE
          }
        )
      end

      class << self
        private

        # Notifications in scope whose subject resolves to an issue in this
        # project, either an Issue subject directly or an AgentRun subject
        # through its issue.
        def subject_issue_scope(project)
          condition = <<~SQL.squish
            (
              (notifications.subject_type = 'Issue' AND EXISTS (
                SELECT 1 FROM issues subject_issues
                WHERE subject_issues.id = notifications.subject_id
                  AND subject_issues.project_id = :project_id
              ))
              OR
              (notifications.subject_type = 'AgentRun' AND EXISTS (
                SELECT 1 FROM agent_runs subject_runs
                INNER JOIN issues run_issues ON run_issues.id = subject_runs.issue_id
                WHERE subject_runs.id = notifications.subject_id
                  AND subject_runs.project_id = :project_id
              ))
            )
          SQL
          Notification.where(Notification.sanitize_sql_array([ condition, project_id: project.id ]))
        end

        def closed_source
          subject_issue_state("closed")
        end

        def open_source
          subject_issue_state("open")
        end

        def subject_issue_state(state)
          condition = <<~SQL.squish
            (
              (notifications.subject_type = 'Issue' AND EXISTS (
                SELECT 1 FROM issues subject_issues
                WHERE subject_issues.id = notifications.subject_id
                  AND subject_issues.github_state = :state
              ))
              OR
              (notifications.subject_type = 'AgentRun' AND EXISTS (
                SELECT 1 FROM agent_runs subject_runs
                INNER JOIN issues run_issues ON run_issues.id = subject_runs.issue_id
                WHERE subject_runs.id = notifications.subject_id
                  AND run_issues.github_state = :state
              ))
            )
          SQL
          Notification.where(Notification.sanitize_sql_array([ condition, state: state ]))
        end
      end
    end
  end
end
