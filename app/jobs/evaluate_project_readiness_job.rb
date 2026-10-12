# frozen_string_literal: true

# Evaluates only on a meaningful state change; Inbox reads the persisted result.
# @spec PROJECT-READINESS-006
class EvaluateProjectReadinessJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound
  retry_on WorktreeService::Error, Errno::ENOENT, wait: :polynomially_longer, attempts: 5

  def perform(project_id)
    project = Project.find(project_id)
    worktree_service = WorktreeService.new(project)
    worktree_service.ensure_cloned

    worktree_service.with_temporary_checkout(worktree_service.current_commit_sha) do |repo_path|
      Projects::Readiness::Record.call(project:, repo_path:)
    end
  end
end
