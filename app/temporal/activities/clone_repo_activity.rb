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

      if agent_run.existing_pr?
        branch_name = fetch_pr_branch(agent_run)
        git_ops.clone_and_checkout_branch(branch_name: branch_name)
      else
        git_ops.clone_and_setup_branch
      end

      create_worktree_record(agent_run)

      { agent_run_id: agent_run_id, branch_name: agent_run.branch_name }
    end

    private

    def fetch_pr_branch(agent_run)
      project = agent_run.project
      client = project.github_token.client
      pr = client.pull_request(project.full_name, agent_run.source_pull_request_number)
      pr.head.ref
    end

    def reconnect_container(agent_run)
      Containers::Provision.reconnect(
        agent_run: agent_run,
        container_id: agent_run.container_id
      )
    end

    def create_worktree_record(agent_run)
      # For existing PR runs the branch name is deterministic, so a cleaned
      # worktree record from a previous run may still exist. Reclaim it
      # instead of failing on the uniqueness constraint.
      existing = Worktree.find_by(
        project: agent_run.project,
        branch_name: agent_run.branch_name
      )

      if existing && !existing.active?
        existing.update!(
          agent_run: agent_run,
          path: "/workspace",
          base_commit: agent_run.base_commit_sha,
          status: "active",
          pushed: false,
          cleaned_at: nil
        )
      else
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
end
