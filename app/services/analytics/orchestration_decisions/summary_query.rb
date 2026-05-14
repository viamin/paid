# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class SummaryQuery < BaseQuery
      def call
        row = filtered_scope
          .left_joins(:agent_run)
          .select(
            "COUNT(*) AS total_count",
            "COUNT(*) FILTER (WHERE #{decision_status_sql} IN ('applied', 'deferred', 'resolved')) AS successful_count",
            "COUNT(*) FILTER (WHERE #{decision_status_sql} = 'noop') AS noop_count",
            "COUNT(*) FILTER (WHERE #{decision_status_sql} = 'failed') AS failed_count",
            "COUNT(DISTINCT orchestration_decisions.agent_run_id) AS linked_agent_run_count",
            "COUNT(DISTINCT agent_runs.id) FILTER (WHERE agent_runs.status = 'completed') AS completed_run_count",
            "COUNT(DISTINCT agent_runs.id) FILTER (WHERE agent_runs.status IN ('failed', 'timeout', 'auth_expired', 'rate_limited', 'cancelled')) AS failed_run_count",
            "COUNT(DISTINCT orchestration_decisions.project_id) AS project_count",
            "COUNT(DISTINCT orchestration_decisions.actor) AS actor_count"
          )
          .take

        {
          total_count: row.total_count.to_i,
          successful_count: row.successful_count.to_i,
          noop_count: row.noop_count.to_i,
          failed_count: row.failed_count.to_i,
          linked_agent_run_count: row.linked_agent_run_count.to_i,
          completed_run_count: row.completed_run_count.to_i,
          failed_run_count: row.failed_run_count.to_i,
          project_count: row.project_count.to_i,
          actor_count: row.actor_count.to_i
        }
      end
    end
  end
end
