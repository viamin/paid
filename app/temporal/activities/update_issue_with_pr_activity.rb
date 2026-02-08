# frozen_string_literal: true

module Activities
  class UpdateIssueWithPrActivity < BaseActivity
    activity_name "UpdateIssueWithPR"

    def execute(agent_run_id:, pull_request_url:)
      agent_run = AgentRun.find(agent_run_id)
      issue = agent_run.issue

      return { agent_run_id: agent_run_id } unless issue

      issue.update!(paid_state: "completed")

      post_pr_comment(agent_run, issue, pull_request_url)

      logger.info(
        message: "agent_execution.issue_updated",
        agent_run_id: agent_run_id,
        issue_id: issue.id,
        pull_request_url: pull_request_url
      )

      { agent_run_id: agent_run_id }
    end

    private

    def post_pr_comment(agent_run, issue, pull_request_url)
      return if pull_request_url.blank?

      client = agent_run.project.github_token.client
      client.add_comment(
        agent_run.project.full_name,
        issue.github_number,
        "Pull request created: #{pull_request_url}"
      )
    rescue => e
      logger.warn(
        message: "agent_execution.issue_comment_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end
  end
end
