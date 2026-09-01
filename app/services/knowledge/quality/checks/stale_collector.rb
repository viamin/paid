# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Surfaces collectors whose latest completed run indexed an older commit
    # than the project's most recently indexed version. Re-collection is
    # overdue for that collector; severity is warning because staleness here
    # usually reflects an upstream collection gap, not user-visible drift.
    class Checks::StaleCollector < Checks::Base
      code "stale_collector"
      severity "warning"

      def findings
        latest = latest_project_version
        return [] unless latest

        latest_runs.filter_map do |type, run|
          next unless run.status == "completed"
          next unless run.project_version&.committed_at
          next unless run.project_version.committed_at < latest.committed_at

          build_finding(
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
        @latest_runs ||= begin
          rows = CollectorRun
            .joins(:project_version)
            .includes(:project_version)
            .where(project_versions: { project_id: project.id })
            .select("DISTINCT ON (collector_runs.collector_type) collector_runs.*")
            .order(:collector_type, created_at: :desc)
            .to_a
          rows.index_by(&:collector_type)
        end
      end

      def latest_project_version
        @latest_project_version ||= project.project_versions
          .where.not(committed_at: nil)
          .order(committed_at: :desc)
          .first
      end
    end
  end
end
