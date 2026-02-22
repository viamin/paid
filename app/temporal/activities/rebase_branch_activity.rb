# frozen_string_literal: true

module Activities
  # Rebases the current branch onto the PR's base branch inside the container.
  #
  # On conflict, returns rebase_succeeded: false so the workflow can instruct
  # the agent to resolve conflicts via merge instead.
  class RebaseBranchActivity < BaseActivity
    activity_name "RebaseBranch"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      project = agent_run.project

      base_branch = fetch_base_branch(agent_run, project)

      container_service = reconnect_container(agent_run)
      git_ops = Containers::GitOperations.new(
        container_service: container_service,
        agent_run: agent_run
      )

      rebase_succeeded = git_ops.rebase_onto(base_branch)

      agent_run.log!("system",
        rebase_succeeded ? "Rebased onto #{base_branch}" : "Rebase onto #{base_branch} failed (conflicts)")

      logger.info(
        message: "agent_execution.rebase_branch",
        agent_run_id: agent_run_id,
        base_branch: base_branch,
        rebase_succeeded: rebase_succeeded
      )

      { agent_run_id: agent_run_id, rebase_succeeded: rebase_succeeded, base_branch: base_branch }
    end

    private

    def fetch_base_branch(agent_run, project)
      client = project.github_token.client
      pr = client.pull_request(project.full_name, agent_run.source_pull_request_number)
      pr.base.ref
    end

    def reconnect_container(agent_run)
      Containers::Provision.reconnect(
        agent_run: agent_run,
        container_id: agent_run.container_id
      )
    end
  end
end
