# frozen_string_literal: true

module Knowledge
  class CollectorRunner
    attr_reader :project, :commit_sha, :branch

    def initialize(project:, commit_sha:, branch: "main")
      @project = project
      @commit_sha = commit_sha
      @branch = branch
    end

    def self.call(...)
      new(...).run
    end

    def self.register(type, klass)
      raise ArgumentError, "collector type must be provided" if type.nil?
      raise ArgumentError, "collector class must be provided" if klass.nil?

      registry[type.to_s] = klass
    end

    def self.registry
      @registry ||= {}
    end

    def self.reset_registry!
      @registry = {}
    end

    def run
      project_version = resolve_project_version
      results = run_collectors(project_version)

      # Only mark stale artifacts when all collectors completed successfully.
      # If any failed, we'd be staling artifacts without a replacement.
      # If any are still running, another worker is mid-collection.
      all_succeeded = results.all? { |r| r[:status] == "completed" || r[:status] == "skipped" }
      mark_stale_artifacts(project_version) if all_succeeded && collector_classes.any?

      {
        project_version: project_version,
        results: results
      }
    end

    private

    def resolve_project_version
      ProjectVersion.create_or_find_by!(
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
      collector_run = CollectorRun.create_or_find_by!(
        project_version: project_version,
        collector_type: collector_type
      )

      collector_run.with_lock do
        if collector_run.status == "completed"
          return { collector_type: collector_type, status: "skipped" }
        end

        if collector_run.status == "running"
          return { collector_type: collector_type, status: "in_progress" }
        end

        collector_run.mark_running!
      end

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

    def mark_stale_artifacts(project_version)
      current_run_ids = project_version.collector_runs.select(:id)

      # Only stale artifacts from versions older than the current one,
      # so backfills of older commits don't stale artifacts from newer versions
      older_version_ids = ProjectVersion
        .where(project: project)
        .where("created_at < ?", project_version.created_at)
        .select(:id)

      ActiveRecord::Base.transaction do
        stale_artifacts = KnowledgeArtifact
          .joins(:collector_run)
          .where(project: project, status: "active")
          .where.not(collector_run_id: current_run_ids)
          .where(collector_runs: { project_version_id: older_version_ids })

        KnowledgeChunk
          .where(knowledge_artifact_id: stale_artifacts.select(:id), status: "active")
          .update_all(status: "stale")

        stale_artifacts.update_all(status: "stale")
      end
    end

    def collector_classes
      self.class.registry
    end
  end
end
