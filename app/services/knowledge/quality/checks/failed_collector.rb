# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Surfaces collectors whose latest run failed as a knowledge-quality
    # finding. We use the latest per-type so an old transient failure that
    # has since recovered does not pollute the report.
    class Checks::FailedCollector < Checks::Base
      code "failed_collector"
      severity "error"

      def findings
        latest_runs.filter_map do |type, run|
          next unless run.status == "failed"

          build_finding(
            target_type: "Collector",
            target_id: type,
            detail: "latest run failed: #{run.error_message.to_s.truncate(200)}",
            extra: { collector_run_id: run.id }
          )
        end
      end

      private

      def latest_runs
        @latest_runs ||= latest_runs_by_type
      end

      def latest_runs_by_type
        rows = CollectorRun
          .joins(:project_version)
          .where(project_versions: { project_id: project.id })
          .select("DISTINCT ON (collector_runs.collector_type) collector_runs.*")
          .order(:collector_type, created_at: :desc)
          .to_a

        rows.index_by(&:collector_type)
      end
    end
  end
end
