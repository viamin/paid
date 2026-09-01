# frozen_string_literal: true

require_relative "base"
require_relative "collector_queries"

module Knowledge
  module Quality
    # Surfaces collectors whose latest completed run indexed an older commit
    # than the project's most recently indexed version. Re-collection is
    # overdue for that collector; severity is warning because staleness here
    # usually reflects an upstream collection gap, not user-visible drift.
    class Checks::StaleCollector < Checks::Base
      include Checks::CollectorQueries

      code "stale_collector"
      severity "warning"

      def collect_findings(collector)
        latest = latest_project_version
        return unless latest

        latest_runs.each do |type, run|
          next unless run.status == "completed"
          next unless run.project_version&.committed_at
          next unless run.project_version.committed_at < latest.committed_at

          add_finding(
            collector,
            target_type: "Collector",
            target_id: type,
            detail: "latest run indexed at #{run.project_version.commit_sha.first(7)}, " \
                    "HEAD is #{latest.commit_sha.first(7)}",
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
