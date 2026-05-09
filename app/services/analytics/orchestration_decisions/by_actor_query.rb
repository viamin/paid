# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class ByActorQuery < BaseQuery
      def call
        rows = filtered_scope
          .group(orchestration_decisions_table[:actor])
          .order(total_count.desc, Arel.sql("LOWER(orchestration_decisions.actor) ASC"))
          .pluck(
            orchestration_decisions_table[:actor],
            total_count,
            project_count,
            decision_type_count,
            distinct_status_count("applied"),
            distinct_status_count("noop"),
            distinct_status_count("failed")
          )

        rows.map do |actor, total_count, project_count, decision_type_count, applied_count, noop_count, failed_count|
          {
            actor: actor,
            total_count: total_count,
            project_count: project_count,
            decision_type_count: decision_type_count,
            applied_count: applied_count,
            noop_count: noop_count,
            failed_count: failed_count
          }
        end
      end
    end
  end
end
