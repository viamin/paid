# frozen_string_literal: true

module Activities
  # Completes an agent run that pushed to an existing PR's branch.
  # Marks the run as completed with the existing PR's URL/number
  # and adds a comment to the PR noting the agent pushed updates.
  class CompleteExistingPrRunActivity < BaseActivity
    activity_name "CompleteExistingPrRun"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      project = agent_run.project
      client = project.github_token.client

      pr = client.pull_request(project.full_name, agent_run.source_pull_request_number)

      agent_run.complete!(
        result_commit: agent_run.result_commit_sha,
        pr_url: pr.html_url,
        pr_number: pr.number
      )

      post_update_comment(client, project, pr.number, agent_run_id)

      agent_run.log!("system", "Pushed updates to existing PR: #{pr.html_url}")

      if agent_run.issue
        agent_run.issue.update!(paid_state: "completed")
      end

      logger.info(
        message: "agent_execution.existing_pr_completed",
        agent_run_id: agent_run_id,
        pull_request_url: pr.html_url
      )

      { agent_run_id: agent_run_id, pull_request_url: pr.html_url, pull_request_number: pr.number }
    end

    private

    def post_update_comment(client, project, pr_number, agent_run_id)
      client.add_comment(
        project.full_name,
        pr_number,
        "Agent pushed updates to this PR."
      )
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.existing_pr_comment_failed",
        agent_run_id: agent_run_id,
        pr_number: pr_number,
        error: e.message
      )
    end
  end
end
