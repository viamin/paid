# frozen_string_literal: true

module Knowledge
  class CollectorRunner
    attr_reader :project, :commit_sha, :branch, :committed_at, :options

    def initialize(project:, commit_sha:, branch: "main", committed_at: nil, options: {})
      @project = project
      @commit_sha = commit_sha
      @branch = branch
      @committed_at = committed_at
      @options = options
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
        pv.committed_at = committed_at
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
        if collector_run.status.in?(%w[completed skipped])
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
        collector_run: collector_run,
        options: options
      )
      tool_version = collector.tool_version
      collector_run.update!(tool_version: tool_version) if tool_version

      artifact_data = collector.collect
      store = ArtifactStore.new(project: project, collector_run: collector_run)
      count = store.store_all(artifact_data)
      collector_run.mark_completed!(count: count)

      { collector_type: collector_type, status: "completed", artifacts_count: count }
    rescue SkipCollector => e
      collector_run&.mark_skipped!(reason: e.reason) if collector_run&.persisted?
      Rails.logger.info(
        message: "knowledge.collector_skipped",
        collector_type: collector_type,
        project_id: project.id,
        reason: e.reason
      )
      { collector_type: collector_type, status: "skipped", reason: e.reason }
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

      # We can only safely determine "older" versions when we know the commit time.
      # If committed_at is nil, skip staling to avoid incorrectly staling newer artifacts
      # when backfilling older commits.
      return unless project_version.committed_at.present?

      reference_timestamp = project_version.committed_at

      older_version_ids = ProjectVersion
        .where(project: project)
        .where("committed_at < ?", reference_timestamp)
        .select(:id)

      ActiveRecord::Base.transaction do
        stale_artifacts = KnowledgeArtifact
          .joins(:collector_run)
          .where(project: project, status: "active")
          .where.not(collector_run_id: current_run_ids)
          .where(collector_runs: { project_version_id: older_version_ids })

        KnowledgeChunk
          .where(knowledge_artifact_id: stale_artifacts.select(:id), status: "active")
          .update_all(status: "stale", updated_at: Time.current)

        stale_artifacts.update_all(status: "stale", updated_at: Time.current)
      end
    end

    def collector_classes
      self.class.registry
    end
  end
end
