# frozen_string_literal: true

class EnqueueKnowledgeCollectionJob < ApplicationJob
  queue_as :knowledge

  self.notification_subsystem = "knowledge"

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

  def perform(project_id) # @spec POLYGLOT-TEST-002
    project = Project.find(project_id)

    worktree_service = WorktreeService.new(project)
    worktree_service.ensure_cloned
    detect_repo_profile(project, worktree_service.repo_path)
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

  def detect_repo_profile(project, repo_path) # @spec POLYGLOT-TEST-002
    profile = Projects::DetectRepoProfile.call(project:, repo_path:)
    project.update!(repo_profile: profile) if profile.present?
  rescue WorktreeService::Error, Errno::ENOENT
    raise
  rescue StandardError => e
    Rails.logger.error(
      message: "knowledge.repo_profile_detection_failed",
      project_id: project.id,
      repo_path: repo_path,
      error: e.message
    )
  end

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
