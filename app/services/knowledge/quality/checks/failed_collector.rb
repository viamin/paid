# frozen_string_literal: true

require_relative "base"
require_relative "collector_queries"

module Knowledge
  module Quality
    # Surfaces collectors whose latest run failed as a knowledge-quality
    # finding. We use the latest per-type so an old transient failure that
    # has since recovered does not pollute the report.
    class Checks::FailedCollector < Checks::Base
      include Checks::CollectorQueries

      code "failed_collector"
      severity "error"

      def collect_findings(collector)
        latest_runs.each do |type, run|
          next unless run.status == "failed"

          add_finding(
            collector,
            target_type: "Collector",
            target_id: type,
            detail: "latest run failed: #{run.error_message.to_s.truncate(200)}",
            extra: { collector_run_id: run.id }
          )
        end
      end

      private

      def latest_runs
        @latest_runs ||= latest_collector_runs_by_type
      end
    end
  end
end
