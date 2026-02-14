# frozen_string_literal: true

module Activities
  class CreateWorktreeActivity < BaseActivity
    activity_name "CreateWorktree"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      worktree_path = agent_run.project.create_worktree_for(agent_run)

      { worktree_path: worktree_path, agent_run_id: agent_run_id }
    end
  end
end
