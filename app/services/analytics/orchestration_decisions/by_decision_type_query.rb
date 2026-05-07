# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class ByDecisionTypeQuery < BaseQuery
      def call
        scope = filtered_scope
          .left_joins(:agent_run)
          .joins(decision_types_join_sql)

        scope = scope.where([ "#{decision_type_sql} IN (?)", decision_types ]) if decision_types.any?

        rows = scope.group(Arel.sql(decision_type_sql))
          .order(Arel.sql("COUNT(DISTINCT decision_records.id) DESC"), Arel.sql("#{decision_type_sql} ASC"))
          .pluck(
            Arel.sql(decision_type_sql),
            Arel.sql("COUNT(DISTINCT decision_records.id)"),
            Arel.sql("COUNT(DISTINCT decision_records.project_id)"),
            Arel.sql("COUNT(DISTINCT CASE WHEN decision_records.status = 'active' THEN decision_records.id END)"),
            Arel.sql("COUNT(DISTINCT CASE WHEN agent_runs.status = 'completed' THEN decision_records.id END)")
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
