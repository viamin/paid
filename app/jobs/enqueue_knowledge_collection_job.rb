# frozen_string_literal: true

class EnqueueKnowledgeCollectionJob < ApplicationJob
  queue_as :knowledge

  discard_on ActiveRecord::RecordNotFound
  retry_on WorktreeService::Error, wait: :polynomially_longer, attempts: 5
  retry_on Errno::ENOENT, wait: :polynomially_longer, attempts: 5

  def perform(project_id)
    project = Project.find(project_id)

    worktree_service = WorktreeService.new(project)
    worktree_service.ensure_cloned
    commit_sha = worktree_service.current_commit_sha

    project.update!(knowledge_status: "collecting") if project.knowledge_status.in?(%w[pending stale])
    detect_import_conventions(project, commit_sha) unless project.project_convention_detections.exists?

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
  rescue StandardError => e
    Rails.logger.error(
      message: "knowledge.import_convention_detection_failed",
      project_id: project.id,
      commit_sha: commit_sha,
      error: e.message
    )
  end
end
