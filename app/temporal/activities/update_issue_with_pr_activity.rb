# frozen_string_literal: true

module Activities
  class UpdateIssueWithPrActivity < BaseActivity
    activity_name "UpdateIssueWithPR"

    def execute(agent_run_id:, pull_request_url:)
      agent_run = AgentRun.find(agent_run_id)
      issue = agent_run.issue

      if issue
        issue.update!(paid_state: "completed")

        logger.info(
          message: "agent_execution.issue_updated",
          agent_run_id: agent_run_id,
          issue_id: issue.id,
          pull_request_url: pull_request_url
        )
      end

      { agent_run_id: agent_run_id }
    end
  end
end
