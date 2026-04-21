# frozen_string_literal: true

module Activities
  class CompleteIssueGoalActivity < BaseActivity
    activity_name "CompleteIssueGoal"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      return result(agent_run) if agent_run.finished?

      track_phase(agent_run_id: agent_run_id, phase_key: "complete_issue_goal", phase_group: "post", agent_run: agent_run) do
        if agent_run.created_issue_url.present?
          completed = agent_run.complete!(
            issue_url: agent_run.created_issue_url,
            issue_number: agent_run.created_issue_number
          )
          if completed
            agent_run.log!("system", "Completed: issue ##{agent_run.created_issue_number} created")

            logger.info(
              message: "agent_execution.issue_goal_completed",
              agent_run_id: agent_run_id,
              issue_url: agent_run.created_issue_url
            )

            ProcessRunQueueJob.perform_later
          end

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

    private

    def result(agent_run)
      {
        agent_run_id: agent_run.id,
        success: agent_run.successful?,
        issue_created: agent_run.created_issue_url.present?,
        skipped: true,
        finished: true,
        cancelled: agent_run.status == "cancelled"
      }
    end
  end
end
