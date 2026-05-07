# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class DailyVolumeQuery < BaseQuery
      def call
        rows = filtered_scope
          .group(Arel.sql("DATE(decision_records.created_at)"))
          .order(Arel.sql("DATE(decision_records.created_at) ASC"))
          .pluck(
            Arel.sql("DATE(decision_records.created_at)"),
            Arel.sql("COUNT(*)"),
            Arel.sql("COUNT(*) FILTER (WHERE decision_records.status = 'active')"),
            Arel.sql("COUNT(*) FILTER (WHERE decision_records.status = 'superseded')"),
            Arel.sql("COUNT(*) FILTER (WHERE decision_records.status = 'reverted')")
          )

        rows.map do |day, total_count, active_count, superseded_count, reverted_count|
          {
            day: day,
            total_count: total_count,
            active_count: active_count,
            superseded_count: superseded_count,
            reverted_count: reverted_count
          }
        end
      end
    end
  end
end
