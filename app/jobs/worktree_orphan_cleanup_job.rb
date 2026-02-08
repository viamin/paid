# frozen_string_literal: true

# Cleans up orphaned git worktrees that are no longer in use.
#
# Worktrees become orphaned when:
# - An agent run completes/fails without proper cleanup
# - A container crashes mid-execution
# - A worker process dies unexpectedly
#
# Scheduled via GoodJob cron.
class WorktreeOrphanCleanupJob < ApplicationJob
  queue_as :maintenance

  def perform
    cleanup_orphaned_worktrees
    prune_active_projects
  end

  private

  def cleanup_orphaned_worktrees
    Worktree.orphaned.find_each do |worktree|
      cleanup_worktree(worktree)
    rescue => e
      Rails.logger.error(
        message: "worktree_cleanup.orphan_failed",
        worktree_id: worktree.id,
        error: e.message
      )
    end
  end

  def prune_active_projects
    Project.active.find_each do |project|
      prune_worktree_refs(project)
    rescue => e
      Rails.logger.error(
        message: "worktree_cleanup.prune_failed",
        project_id: project.id,
        error: e.message
      )
    end
  end

  def cleanup_worktree(worktree)
    repo_path = worktree_repo_path(worktree.project)
    worktree_remove_failed = false

    WorktreeService.mutex_for(repo_path).synchronize do
      if worktree.path.present? && Dir.exist?(worktree.path) && Dir.exist?(repo_path)
        unless system("git", "-C", repo_path, "worktree", "remove", worktree.path, "--force", exception: false)
          Rails.logger.warn(
            message: "worktree_cleanup.worktree_remove_failed",
            worktree_id: worktree.id,
            path: worktree.path
          )
          worktree_remove_failed = true
        end
      end

      if !worktree.pushed? && worktree.branch_name.present? && Dir.exist?(repo_path)
        unless system("git", "-C", repo_path, "branch", "-D", worktree.branch_name, exception: false)
          Rails.logger.warn(
            message: "worktree_cleanup.branch_delete_failed",
            worktree_id: worktree.id,
            branch_name: worktree.branch_name
          )
        end
      end

      if Dir.exist?(repo_path)
        prune_worktree_refs(worktree.project)
      end
    end

    if worktree_remove_failed
      worktree.mark_cleanup_failed!
    else
      worktree.mark_cleaned!
    end
  end

  def prune_worktree_refs(project)
    repo_path = worktree_repo_path(project)
    return unless Dir.exist?(repo_path)

    unless system("git", "-C", repo_path, "worktree", "prune")
      Rails.logger.warn(
        message: "worktree_cleanup.prune_command_failed",
        project_id: project.id,
        repo_path: repo_path
      )
    end
  end

  def worktree_repo_path(project)
    File.join(
      WorktreeService::WORKSPACE_ROOT,
      project.account_id.to_s,
      project.id.to_s,
      "repo"
    )
  end
end
