# frozen_string_literal: true

module Knowledge
  module Quality
    module Checks::CollectorQueries
      private

      def latest_collector_runs_by_type
        @latest_collector_runs_by_type ||= CollectorRun
          .joins(:project_version)
          .includes(:project_version)
          .where(project_versions: { project_id: project.id })
          .select("DISTINCT ON (collector_runs.collector_type) collector_runs.*")
          .order(:collector_type, created_at: :desc)
          .index_by(&:collector_type)
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
