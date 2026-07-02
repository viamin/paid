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

      if should_mark_stale_artifacts?(results) && full_collection_run?
        mark_stale_artifacts(project_version, preserved_collector_types(results))
      end

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
        if collector_run.status == "completed"
          return { collector_type: collector_type, status: "completed", cached: true }
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
    rescue Knowledge::SkipCollector => e
      if collector_run&.persisted?
        collector_run.mark_skipped!(
          reason: e.reason,
          artifacts_count: skipped_artifacts_count(
            collector_type: collector_type,
            preserve_existing_artifacts: e.preserve_existing_artifacts?
          )
        )
      end
      Rails.logger.info(
        message: "knowledge.collector_skipped",
        collector_type: collector_type,
        project_id: project.id,
        reason: e.reason,
        preserve_existing_artifacts: e.preserve_existing_artifacts?
      )
      {
        collector_type: collector_type,
        status: "skipped",
        reason: e.reason,
        preserve_existing_artifacts: e.preserve_existing_artifacts?
      }
    rescue ApplicationJob::PerformTimeoutError
      collector_run&.mark_failed!(error: "perform timeout") if collector_run&.persisted?
      raise
    rescue StandardError => e
      collector_run&.mark_failed!(error: e.message) if collector_run&.persisted?
      Rails.logger.error(
        message: "knowledge.collector_failed",
        collector_type: collector_type,
        project_id: project.id,
        error: e.message
      )
      { collector_type: collector_type, status: "failed", error: e.message }
    end

    def should_mark_stale_artifacts?(results)
      return false unless collector_classes.any?

      results.all? do |result|
        %w[completed skipped].include?(result[:status])
      end
    end

    def preserved_collector_types(results)
      results.filter_map do |result|
        result[:collector_type] if result[:status] == "skipped" && result[:preserve_existing_artifacts]
      end
    end

    def mark_stale_artifacts(project_version, preserved_types = [])
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
        if preserved_types.any?
          stale_artifacts = stale_artifacts.where.not(knowledge_artifacts: { collector_type: preserved_types })
        end

        KnowledgeChunk
          .where(knowledge_artifact_id: stale_artifacts.select(:id), status: "active")
          .update_all(status: "stale", updated_at: Time.current)

        stale_artifacts.update_all(status: "stale", updated_at: Time.current)
      end
    end

    def collector_classes
      @collector_classes ||= begin
        requested_types = Array(options[:collector_types]).map(&:to_s).uniq
        registry = self.class.registry
        if requested_types.empty?
          registry
        else
          missing_types = requested_types - registry.keys
          if missing_types.any?
            raise ArgumentError, "Unknown collector types: #{missing_types.join(', ')}"
          end

          registry.slice(*requested_types)
        end
      end
    end

    def full_collection_run?
      requested_types = Array(options[:collector_types]).map(&:to_s).uniq
      requested_types.empty? || requested_types.sort == self.class.registry.keys.sort
    end

    def skipped_artifacts_count(collector_type:, preserve_existing_artifacts:)
      return 0 unless preserve_existing_artifacts

      project.knowledge_artifacts.active.where(collector_type: collector_type).count
    end
  end
end
