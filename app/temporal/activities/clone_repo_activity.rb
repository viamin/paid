# frozen_string_literal: true

module Activities
  # Clones a repository and creates a working branch inside an already-provisioned container.
  #
  # Replaces the host-side CreateWorktreeActivity. Git operations run inside
  # the container, authenticated via the git credential helper proxy.
  class CloneRepoActivity < BaseActivity
    activity_name "CloneRepo"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      container_service = reconnect_container(agent_run)
      git_ops = Containers::GitOperations.new(
        container_service: container_service,
        agent_run: agent_run
      )
      git_ops.clone_and_setup_branch

      create_worktree_record(agent_run)

      { agent_run_id: agent_run_id, branch_name: agent_run.branch_name }
    end

    private

    def reconnect_container(agent_run)
      Containers::Provision.reconnect(
        agent_run: agent_run,
        container_id: agent_run.container_id
      )
    end

    def create_worktree_record(agent_run)
      Worktree.create!(
        project: agent_run.project,
        agent_run: agent_run,
        path: "/workspace",
        branch_name: agent_run.branch_name,
        base_commit: agent_run.base_commit_sha,
        status: "active"
      )
    end
  end
end
