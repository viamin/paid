# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class SummaryQuery < BaseQuery
      def call
        row = filtered_scope
          .left_joins(:agent_run)
          .select(
            "COUNT(*) AS total_count",
            "COUNT(*) FILTER (WHERE decision_records.status = 'active') AS active_count",
            "COUNT(*) FILTER (WHERE decision_records.status = 'superseded') AS superseded_count",
            "COUNT(*) FILTER (WHERE decision_records.status = 'reverted') AS reverted_count",
            "COUNT(*) FILTER (WHERE decision_records.agent_run_id IS NOT NULL) AS linked_agent_run_count",
            "COUNT(*) FILTER (WHERE agent_runs.status = 'completed') AS completed_run_count",
            "COUNT(*) FILTER (WHERE agent_runs.status IN ('failed', 'timeout', 'auth_expired', 'rate_limited', 'cancelled')) AS failed_run_count"
          )
          .take

        {
          total_count: row.total_count.to_i,
          active_count: row.active_count.to_i,
          superseded_count: row.superseded_count.to_i,
          reverted_count: row.reverted_count.to_i,
          linked_agent_run_count: row.linked_agent_run_count.to_i,
          completed_run_count: row.completed_run_count.to_i,
          failed_run_count: row.failed_run_count.to_i
        }
      end
    end
  end
end
