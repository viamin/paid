# frozen_string_literal: true

module Activities
  class MarkAgentRunFailedActivity < BaseActivity
    activity_name "MarkAgentRunFailed"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      error = input[:error]
      agent_run = AgentRun.find(agent_run_id)

      agent_run.fail!(error: error)
      agent_run.log!("system", "Agent run failed: #{error}")

      if agent_run.issue
        agent_run.issue.update!(paid_state: "failed")
      end

      logger.info(
        message: "agent_execution.failed",
        agent_run_id: agent_run_id,
        error: error
      )

      { agent_run_id: agent_run_id }
    end
  end
end
