# frozen_string_literal: true

class RunCollectorsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :knowledge
  self.notification_subsystem = "knowledge"

  # Backstop against a collector run hanging indefinitely on container/git/network
  # I/O. Inner per-command timeouts are 30s each; 20 minutes leaves ample room for
  # a full multi-collector run while guaranteeing the job cannot hang forever.
  self.perform_timeout = 20.minutes.to_i

  discard_on ActiveRecord::RecordNotFound

  # Prevent duplicate enqueues for the same project+SHA when staleness detection
  # polls frequently and the prior job hasn't started yet.
  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "run_collectors_#{arguments[0]}_#{arguments[1]}" }
  )

  def notification_project_id
    arguments.first
  end

  def perform(project_id, commit_sha, branch: "main", committed_at: nil)
    project = Project.find(project_id)
    project.update!(knowledge_status: "collecting") unless project.knowledge_status == "collecting"

    result = if Knowledge::ContainerizedRunner.available?
      Knowledge::ContainerizedRunner.call(
        project: project,
        commit_sha: commit_sha,
        branch: branch,
        committed_at: committed_at
      )
    else
      Knowledge::CollectorRunner.call(
        project: project,
        commit_sha: commit_sha,
        branch: branch,
        committed_at: committed_at
      )
    end

    update_knowledge_status(project, result)
  rescue ActiveRecord::RecordNotFound
    raise # Re-raise so discard_on can handle it above the StandardError rescue
  rescue StandardError
    begin
      project&.update(knowledge_status: "failed") unless project&.knowledge_status == "failed"
      KnowledgeArtifact.bust_artifact_counts_cache(project.id) if project
    rescue StandardError => update_error
      Rails.logger.error(
        message: "knowledge.job_status_update_failed",
        project_id: project&.id,
        error: update_error.message
      )
    end
    raise
  end

  private

  def update_knowledge_status(project, result)
    statuses = Array(result&.dig(:results)).map { |r| r[:status] }
    terminal = false
    if statuses.empty?
      project.update!(knowledge_status: "failed")
      terminal = true
    elsif statuses.any? { |s| s == "failed" }
      project.update!(knowledge_status: "failed")
      terminal = true
    elsif statuses.all? { |s| s == "completed" || s == "skipped" }
      project.update!(knowledge_status: "ready")
      terminal = true
    elsif statuses.any? { |s| s == "in_progress" }
      project.update!(knowledge_status: "collecting") unless project.knowledge_status == "collecting"
    else
      Rails.logger.warn(
        message: "knowledge.unhandled_statuses",
        project_id: project.id,
        statuses: statuses
      )
    end
    KnowledgeArtifact.bust_artifact_counts_cache(project.id) if terminal
  rescue StandardError => e
    Rails.logger.error(message: "knowledge.status_update_failed", project_id: project.id, error: e.message)
    raise
  end
end
