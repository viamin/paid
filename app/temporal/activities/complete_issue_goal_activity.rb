# frozen_string_literal: true

module Activities
  class CompleteIssueGoalActivity < BaseActivity
    activity_name "CompleteIssueGoal"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      if agent_run.created_issue_url.present?
        agent_run.complete!(
          issue_url: agent_run.created_issue_url,
          issue_number: agent_run.created_issue_number
        )
        agent_run.log!("system", "Completed: issue ##{agent_run.created_issue_number} created")

        logger.info(
          message: "agent_execution.issue_goal_completed",
          agent_run_id: agent_run_id,
          issue_url: agent_run.created_issue_url
        )

        ProcessRunQueueJob.perform_later

        { agent_run_id: agent_run_id, success: true }
      else
        agent_run.fail!(error: "Agent did not create an issue")
        agent_run.log!("system", "Failed: no issue was created by the agent")

        logger.info(
          message: "agent_execution.issue_goal_failed",
          agent_run_id: agent_run_id
        )

        ProcessRunQueueJob.perform_later

        raise Temporalio::Error::ApplicationError.new(
          "Agent did not create an issue",
          type: "IssueGoalNotMet"
        )
      end
    end
  end
end
