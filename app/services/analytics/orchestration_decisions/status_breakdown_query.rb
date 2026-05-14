# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class StatusBreakdownQuery < BaseQuery
      def call
        rows = filtered_scope
          .group(Arel.sql(decision_status_sql))
          .order(total_count.desc, Arel.sql("#{decision_status_sql} ASC"))
          .pluck(
            Arel.sql(decision_status_sql),
            total_count
          )

        rows.map do |decision_status, total_count|
          {
            decision_status: decision_status,
            total_count: total_count,
            analytics_group: OrchestrationDecision.analytics_status_group(decision_status)
          }
        end
      end
    end
  end
end
