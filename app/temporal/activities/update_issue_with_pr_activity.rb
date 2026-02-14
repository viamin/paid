# frozen_string_literal: true

module Activities
  class UpdateIssueWithPrActivity < BaseActivity
    activity_name "UpdateIssueWithPR"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      pull_request_url = input[:pull_request_url]
      agent_run = AgentRun.find(agent_run_id)
      issue = agent_run.issue

      return { agent_run_id: agent_run_id } unless issue

      project = agent_run.project
      client = project.github_token.client

      issue.update!(paid_state: "completed")

      post_pr_comment(client, project, issue, pull_request_url, agent_run_id)
      remove_trigger_labels(client, project, issue, agent_run_id)

      agent_run.log!("system", "Issue ##{issue.github_number} updated with PR link")

      logger.info(
        message: "agent_execution.issue_updated",
        agent_run_id: agent_run_id,
        issue_id: issue.id,
        pull_request_url: pull_request_url
      )

      { agent_run_id: agent_run_id }
    end

    private

    def post_pr_comment(client, project, issue, pull_request_url, agent_run_id)
      return if pull_request_url.blank?

      client.add_comment(
        project.full_name,
        issue.github_number,
        "Pull request created: #{pull_request_url}"
      )
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.issue_comment_failed",
        agent_run_id: agent_run_id,
        issue_number: issue.github_number,
        error: e.message
      )
    end

    def remove_trigger_labels(client, project, issue, agent_run_id)
      %w[build plan].each do |stage|
        label = project.label_for_stage(stage)
        next unless label && issue.has_label?(label)

        client.remove_label_from_issue(project.full_name, issue.github_number, label)
      end
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.remove_trigger_label_failed",
        agent_run_id: agent_run_id,
        issue_number: issue.github_number,
        error: e.message
      )
    end
  end
end
