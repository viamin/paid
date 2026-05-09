# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class ByDecisionTypeQuery < BaseQuery
      def call
        scope = filtered_scope
          .left_joins(:agent_run)

        rows = scope.group(orchestration_decisions_table[:decision_type])
          .order(total_count.desc, orchestration_decisions_table[:decision_type].asc)
          .pluck(
            orchestration_decisions_table[:decision_type],
            total_count,
            project_count,
            actor_count,
            distinct_status_count("failed"),
            distinct_completed_run_count
          )

        rows.map do |decision_type, total_count, project_count, actor_count, failed_count, completed_run_count|
          {
            decision_type: decision_type,
            total_count: total_count,
            project_count: project_count,
            actor_count: actor_count,
            failed_count: failed_count,
            completed_run_count: completed_run_count
          }
        end
      end
    end
  end
end
