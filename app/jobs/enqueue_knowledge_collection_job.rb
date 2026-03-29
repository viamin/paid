# frozen_string_literal: true

class EnqueueKnowledgeCollectionJob < ApplicationJob
  queue_as :default

  retry_on WorktreeService::Error, wait: :polynomially_longer, attempts: 5
  retry_on Errno::ENOENT, wait: :polynomially_longer, attempts: 5

  def perform(project_id)
    project = Project.find(project_id)

    worktree_service = WorktreeService.new(project)
    worktree_service.ensure_cloned
    commit_sha = worktree_service.current_commit_sha

    project.update!(knowledge_status: "collecting")

    RunCollectorsJob.perform_later(
      project.id,
      commit_sha,
      branch: project.default_branch
    )
  end
end
