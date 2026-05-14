# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class DailyVolumeQuery < BaseQuery
      def call
        rows = filtered_scope
          .group(Arel.sql("DATE(orchestration_decisions.created_at)"))
          .order(Arel.sql("DATE(orchestration_decisions.created_at) ASC"))
          .pluck(
            Arel.sql("DATE(orchestration_decisions.created_at)"),
            Arel.sql("COUNT(*)"),
            status_count(grouped_statuses("successful")),
            status_count("noop"),
            status_count("failed")
          )

        rows.map do |day, total_count, successful_count, noop_count, failed_count|
          {
            day: day,
            total_count: total_count,
            successful_count: successful_count,
            noop_count: noop_count,
            failed_count: failed_count
          }
        end
      end
    end
  end
end
