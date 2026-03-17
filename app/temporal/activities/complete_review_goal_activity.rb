# frozen_string_literal: true

module Activities
  class CompleteReviewGoalActivity < BaseActivity
    activity_name "CompleteReviewGoal"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      agent_run.complete!(
        pr_number: agent_run.source_pull_request_number
      )
      agent_run.log!("system", "Completed: review posted on PR ##{agent_run.source_pull_request_number}")

      logger.info(
        message: "agent_execution.review_goal_completed",
        agent_run_id: agent_run_id,
        pr_number: agent_run.source_pull_request_number
      )

      ProcessRunQueueJob.perform_later

      { agent_run_id: agent_run_id, success: true }
    end
  end
end
