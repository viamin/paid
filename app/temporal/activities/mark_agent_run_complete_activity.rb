# frozen_string_literal: true

module Activities
  class MarkAgentRunCompleteActivity < BaseActivity
    activity_name "MarkAgentRunComplete"

    def execute(agent_run_id:, reason: "no_changes")
      agent_run = AgentRun.find(agent_run_id)

      agent_run.complete!
      agent_run.log!("system", "Completed without PR: #{reason}")

      if agent_run.issue
        agent_run.issue.update!(paid_state: "completed")
      end

      logger.info(
        message: "agent_execution.completed_without_pr",
        agent_run_id: agent_run_id,
        reason: reason
      )

      { agent_run_id: agent_run_id }
    end
  end
end
