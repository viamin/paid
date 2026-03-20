# frozen_string_literal: true

module Activities
  class CompleteIssueGoalActivity < BaseActivity
    activity_name "CompleteIssueGoal"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      track_phase(agent_run_id: agent_run_id, phase_key: "complete_issue_goal", phase_group: "post") do
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

          { agent_run_id: agent_run_id, success: true, issue_created: true }
        else
          agent_run.log!("system", "Agent did not create an issue directly; falling back to platform issue creation")

          logger.info(
            message: "agent_execution.issue_goal_fallback",
            agent_run_id: agent_run_id
          )

          { agent_run_id: agent_run_id, success: true, issue_created: false }
        end
      end
    end
  end
end
