# frozen_string_literal: true

class RunCollectorsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  # Prevent duplicate enqueues for the same project+SHA when staleness detection
  # polls frequently and the prior job hasn't started yet.
  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "run_collectors_#{arguments[0]}_#{arguments[1]}" }
  )

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
    raise
  rescue StandardError
    project&.update!(knowledge_status: "failed") unless project&.knowledge_status == "failed"
    raise
  end

  private

  def update_knowledge_status(project, result)
    statuses = Array(result&.dig(:results)).map { |r| r[:status] }
    if statuses.empty?
      project.update!(knowledge_status: "failed")
    elsif statuses.any? { |s| s == "failed" }
      project.update!(knowledge_status: "failed")
    elsif statuses.all? { |s| s == "completed" || s == "skipped" }
      project.update!(knowledge_status: "ready")
    end
  rescue StandardError => e
    Rails.logger.error(message: "knowledge.status_update_failed", project_id: project.id, error: e.message)
    raise
  end
end
