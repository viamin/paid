# frozen_string_literal: true

module Activities
  class PushBranchActivity < BaseActivity
    activity_name "PushBranch"

    def execute(agent_run_id:)
      agent_run = AgentRun.find(agent_run_id)
      commit_sha = agent_run.project.push_branch_for(agent_run)

      { commit_sha: commit_sha, agent_run_id: agent_run_id }
    end
  end
end
