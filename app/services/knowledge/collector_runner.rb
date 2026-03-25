# frozen_string_literal: true

module Knowledge
  class CollectorRunner
    attr_reader :project, :commit_sha, :branch

    REGISTRY = {}.freeze

    def initialize(project:, commit_sha:, branch: "main")
      @project = project
      @commit_sha = commit_sha
      @branch = branch
    end

    def self.call(...)
      new(...).run
    end

    def self.registry
      REGISTRY
    end

    def run
      project_version = resolve_project_version
      results = run_collectors(project_version)
      mark_stale_artifacts(project_version)

      {
        project_version: project_version,
        results: results
      }
    end

    private

    def resolve_project_version
      ProjectVersion.find_or_create_by!(
        project: project,
        commit_sha: commit_sha
      ) do |pv|
        pv.branch = branch
      end
    end

    def run_collectors(project_version)
      collector_classes.map do |collector_type, collector_class|
        run_single_collector(project_version, collector_type, collector_class)
      end
    end

    def run_single_collector(project_version, collector_type, collector_class)
      collector_run = CollectorRun.find_or_initialize_by(
        project_version: project_version,
        collector_type: collector_type
      )

      return skip_result(collector_type) if collector_run.persisted? && collector_run.status == "completed"

      collector_run.save! if collector_run.new_record?
      collector_run.mark_running!

      collector = collector_class.new(
        project: project,
        project_version: project_version,
        collector_run: collector_run
      )
      collector_run.update!(tool_version: collector.tool_version) if collector.tool_version

      artifact_data = collector.collect
      store = ArtifactStore.new(project: project, collector_run: collector_run)
      count = store.store_all(artifact_data)
      collector_run.mark_completed!(count: count)

      { collector_type: collector_type, status: "completed", artifacts_count: count }
    rescue => e
      collector_run&.mark_failed!(error: e.message) if collector_run&.persisted?
      Rails.logger.error(
        message: "knowledge.collector_failed",
        collector_type: collector_type,
        project_id: project.id,
        error: e.message
      )
      { collector_type: collector_type, status: "failed", error: e.message }
    end

    def skip_result(collector_type)
      { collector_type: collector_type, status: "skipped" }
    end

    def mark_stale_artifacts(project_version)
      KnowledgeArtifact
        .where(project: project, status: "active")
        .where.not(collector_run_id: project_version.collector_runs.select(:id))
        .update_all(status: "stale")
    end

    def collector_classes
      self.class.registry
    end
  end
end
