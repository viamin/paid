# frozen_string_literal: true

module Activities
  # Cleans up the Worktree database record after an agent run.
  #
  # The actual worktree directory (inside the container) is cleaned up by
  # CleanupContainerActivity when the container and workspace are removed.
  # This activity only handles the database record.
  class CleanupWorktreeActivity < BaseActivity
    activity_name "CleanupWorktree"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find_by(id: agent_run_id)
      unless agent_run
        logger.info(message: "agent_execution.cleanup_worktree_skipped_missing_run", agent_run_id: agent_run_id)
        return { agent_run_id: agent_run_id }
      end

      track_phase(agent_run_id: agent_run_id, phase_key: "cleanup_worktree", phase_group: "cleanup", agent_run: agent_run) do
        worktree = agent_run.worktree
        worktree&.mark_cleaned! if worktree&.active?

        { agent_run_id: agent_run_id }
      end
    end
  end
end
