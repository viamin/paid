# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class OutcomeByDecisionTypeQuery < BaseQuery
      def call
        rows = filtered_scope
          .group(orchestration_decisions_table[:decision_type])
          .order(total_count.desc, orchestration_decisions_table[:decision_type].asc)
          .pluck(
            orchestration_decisions_table[:decision_type],
            total_count,
            distinct_status_count("applied"),
            distinct_status_count("noop"),
            distinct_status_count("failed")
          )

        rows.map do |decision_type, total_count, applied_count, noop_count, failed_count|
          {
            decision_type: decision_type,
            total_count: total_count,
            applied_count: applied_count,
            noop_count: noop_count,
            failed_count: failed_count
          }
        end
      end
    end
  end
end
