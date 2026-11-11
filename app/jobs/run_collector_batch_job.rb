# frozen_string_literal: true

# Runs one collector per GoodJob perform so large repositories cannot retain
# every collector's working set in Puma for an entire collection cycle.
# @spec KNOWLEDGE-014
class RunCollectorBatchJob < RunCollectorsJob
  queue_as :knowledge

  good_job_control_concurrency_with(
    total_limit: 1,
    perform_limit: 1,
    key: -> { "run_collectors_#{arguments[0]}_#{arguments[1]}" }
  )

  def perform(project_id, commit_sha, branch: "main", committed_at: nil,
    collector_index: 0, collector_types: nil, preserved_collector_types: [], collector_cursor: nil)
    project = Project.find(project_id)
    return if superseded_commit?(project, branch, commit_sha)
    return if collector_index.zero? && continuation_pending?(project_id, commit_sha)

    collector_types ||= Knowledge::CollectorRunner.registry.keys
    raise ArgumentError, "no knowledge collectors registered" if collector_types.empty?

    collector_type = collector_types.fetch(collector_index)
    result = super(project_id, commit_sha, branch:, committed_at:, collector_type:, collector_cursor:)
    outcome = result.fetch(:results).find { |item| item[:collector_type] == collector_type }
    status = outcome&.fetch(:status)
    if status == "in_progress"
      RunCollectorContinuationJob.set(wait: 1.minute).perform_later(project_id, commit_sha, branch:, committed_at:,
        collector_index:, collector_types:, preserved_collector_types:, collector_cursor: outcome[:cursor])
      return
    end
    unless %w[completed skipped].include?(status)
      Project.find(project_id).update!(knowledge_status: "failed")
      return
    end

    preserved_collector_types += [ collector_type ] if outcome[:preserve_existing_artifacts]
    if collector_index + 1 < collector_types.size
      RunCollectorContinuationJob.perform_later(project_id, commit_sha, branch:, committed_at:,
        collector_index: collector_index + 1, collector_types:, preserved_collector_types:)
      return
    end

    finalized = Knowledge::CollectorRunner.finalize_collection(project: Project.find(project_id), commit_sha:,
      collector_types:, preserved_collector_types:)
    raise "collector chain could not be finalized" unless finalized

    Project.find(project_id).update!(knowledge_status: "ready")
    KnowledgeArtifact.bust_artifact_counts_cache(project_id)
  rescue ActiveRecord::RecordNotFound, Knowledge::ArtifactStore::LockUnavailable,
    ActiveRecord::ConnectionNotEstablished
    raise
  rescue StandardError
    mark_knowledge_collection_failed(Project.find_by(id: project_id))
    raise
  end

  private

  def superseded_commit?(project, branch, commit_sha)
    current_sha = project.client.ref(project.full_name, "heads/#{branch}")&.object&.sha
    return false if current_sha.blank? || current_sha == commit_sha

    Rails.logger.info(message: "knowledge.collection_superseded", project_id: project.id,
      commit_sha:, branch:, current_sha:)
    true
  rescue GithubClient::Error, Faraday::Error
    false
  end

  def continuation_pending?(project_id, commit_sha)
    GoodJob::Job.unfinished.where(job_class: RunCollectorContinuationJob.name,
      concurrency_key: "run_collectors_#{project_id}_#{commit_sha}").exists?
  end
end
