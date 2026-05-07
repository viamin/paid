# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class ByProjectQuery < BaseQuery
      def call
        total_count = distinct_count(decision_records_table[:id])
        decision_type_count = distinct_count(decision_type_expression)

        scope = filtered_scope
          .joins(:project)
          .joins(decision_types_join_sql)

        scope = scope.where(decision_type_expression.in(decision_types)) if decision_types.any?

        rows = scope
          .group(
            projects_table[:id],
            projects_table[:name],
            projects_table[:owner],
            projects_table[:repo]
          )
          .order(total_count.desc, projects_table[:name].asc)
          .pluck(
            projects_table[:id],
            projects_table[:name],
            projects_table[:owner],
            projects_table[:repo],
            total_count,
            decision_type_count,
            distinct_status_count("active"),
            distinct_status_count("superseded"),
            distinct_status_count("reverted")
          )

        rows.map do |project_id, name, owner, repo, total_count, decision_type_count, active_count, superseded_count, reverted_count|
          {
            project_id: project_id,
            project_name: name,
            project_full_name: "#{owner}/#{repo}",
            total_count: total_count,
            decision_type_count: decision_type_count,
            active_count: active_count,
            superseded_count: superseded_count,
            reverted_count: reverted_count
          }
        end
      end
    end
  end
end
