# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class ByProjectQuery < BaseQuery
      def call
        scope = filtered_scope
          .joins(:project)

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
            actor_count,
            distinct_status_count(grouped_statuses("successful")),
            distinct_status_count("noop"),
            distinct_status_count("failed")
          )

        rows.map do |project_id, name, owner, repo, total_count, decision_type_count, actor_count, successful_count, noop_count, failed_count|
          {
            project_id: project_id,
            project_name: name,
            project_full_name: "#{owner}/#{repo}",
            total_count: total_count,
            decision_type_count: decision_type_count,
            actor_count: actor_count,
            successful_count: successful_count,
            noop_count: noop_count,
            failed_count: failed_count
          }
        end
      end
    end
  end
end
