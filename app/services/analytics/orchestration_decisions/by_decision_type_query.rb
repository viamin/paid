# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class ByDecisionTypeQuery < BaseQuery
      def call
        total_count = distinct_count(decision_records_table[:id])

        scope = filtered_scope
          .left_joins(:agent_run)
          .joins(decision_types_join_sql)

        scope = scope.where(decision_type_expression.in(decision_types)) if decision_types.any?

        rows = scope.group(decision_type_expression)
          .order(total_count.desc, decision_type_expression.asc)
          .pluck(
            decision_type_expression,
            total_count,
            distinct_count(decision_records_table[:project_id]),
            distinct_status_count("active"),
            distinct_completed_run_count
          )

        rows.map do |decision_type, total_count, project_count, active_count, completed_run_count|
          {
            decision_type: decision_type,
            total_count: total_count,
            project_count: project_count,
            active_count: active_count,
            completed_run_count: completed_run_count
          }
        end
      end
    end
  end
end
