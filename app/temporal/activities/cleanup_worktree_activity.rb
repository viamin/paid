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
      agent_run = AgentRun.find(agent_run_id)

      worktree = agent_run.worktree
      worktree&.mark_cleaned! if worktree&.active?

      { agent_run_id: agent_run_id }
    end
  end
end
