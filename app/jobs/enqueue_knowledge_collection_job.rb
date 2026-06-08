# frozen_string_literal: true

class EnqueueKnowledgeCollectionJob < ApplicationJob
  queue_as :knowledge

  self.notification_subsystem = "knowledge"
  self.max_attempts = 5

  discard_on ActiveRecord::RecordNotFound

  # retry_on intercepts these errors before ApplicationJob's rescue_from hook, so
  # notify explicitly when the final attempt is exhausted, then re-raise.
  retry_on WorktreeService::Error, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.notify_terminal_failure(error)
    raise error
  end
  retry_on Errno::ENOENT, wait: :polynomially_longer, attempts: 5 do |job, error|
    job.notify_terminal_failure(error)
    raise error
  end

  def notification_project_id
    arguments.first
  end

  def perform(project_id)
    project = Project.find(project_id)

    worktree_service = WorktreeService.new(project)
    worktree_service.ensure_cloned
    commit_sha = worktree_service.current_commit_sha

    project.update!(knowledge_status: "collecting") if project.knowledge_status.in?(%w[pending stale])
    detect_import_conventions(project, commit_sha)

    RunCollectorsJob.perform_later(
      project.id,
      commit_sha,
      branch: project.default_branch
    )
  end

  private

  def detect_import_conventions(project, commit_sha)
    ProjectConventions::DetectForImport.call(
      project: project,
      commit_sha: commit_sha,
      branch: project.default_branch
    )
  rescue WorktreeService::Error, Errno::ENOENT
    raise
  rescue StandardError => e
    Rails.logger.error(
      message: "knowledge.import_convention_detection_failed",
      project_id: project.id,
      commit_sha: commit_sha,
      error: e.message
    )
  end
end
