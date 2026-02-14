# frozen_string_literal: true

module Activities
  class CleanupWorktreeActivity < BaseActivity
    activity_name "CleanupWorktree"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      agent_run.project.remove_worktree_for(agent_run)

      { agent_run_id: agent_run_id }
    end
  end
end
