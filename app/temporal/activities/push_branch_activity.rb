# frozen_string_literal: true

module Activities
  # Pushes the agent's branch to the remote from inside the container.
  #
  # Git push runs inside the container, authenticated via the git credential
  # helper proxy. No git credentials touch the host.
  class PushBranchActivity < BaseActivity
    activity_name "PushBranch"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      container_service = Containers::Provision.reconnect(
        agent_run: agent_run,
        container_id: agent_run.container_id
      )

      git_ops = Containers::GitOperations.new(
        container_service: container_service,
        agent_run: agent_run
      )

      commit_sha = git_ops.push_branch

      { commit_sha: commit_sha, agent_run_id: agent_run_id }
    end
  end
end
