# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class ByProjectQuery < BaseQuery
      def call
        rows = filtered_scope
          .joins(:project)
          .joins(decision_types_join_sql)
          .group("projects.id", "projects.name", "projects.owner", "projects.repo")
          .order(Arel.sql("COUNT(DISTINCT decision_records.id) DESC"), "projects.name ASC")
          .pluck(
            "projects.id",
            "projects.name",
            "projects.owner",
            "projects.repo",
            Arel.sql("COUNT(DISTINCT decision_records.id)"),
            Arel.sql("COUNT(DISTINCT #{decision_type_sql})"),
            Arel.sql("COUNT(DISTINCT CASE WHEN decision_records.status = 'active' THEN decision_records.id END)"),
            Arel.sql("COUNT(DISTINCT CASE WHEN decision_records.status = 'superseded' THEN decision_records.id END)"),
            Arel.sql("COUNT(DISTINCT CASE WHEN decision_records.status = 'reverted' THEN decision_records.id END)")
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
