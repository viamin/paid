# frozen_string_literal: true

module Activities
  class MarkAgentRunFailedActivity < BaseActivity
    activity_name "MarkAgentRunFailed"

    def execute(agent_run_id:, error:)
      agent_run = AgentRun.find(agent_run_id)
      agent_run.fail!(error: error)
      agent_run.log!("system", "Agent run failed: #{error}")

      if agent_run.issue
        agent_run.issue.update!(paid_state: "failed")
      end

      if agent_run.temporal_workflow_id
        update_workflow_state(agent_run.temporal_workflow_id, {
          workflow_type: "AgentExecution",
          status: "failed",
          completed_at: Time.current,
          error_message: error
        })
      end

      logger.info(
        message: "agent_execution.run_failed",
        agent_run_id: agent_run_id,
        error: error
      )

      { agent_run_id: agent_run_id }
    end
  end
end
