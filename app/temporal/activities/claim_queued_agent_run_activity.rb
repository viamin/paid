# frozen_string_literal: true

module Activities
  class ClaimQueuedAgentRunActivity < BaseActivity
    activity_name "ClaimQueuedAgentRun"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      workflow_id = input[:workflow_id]

      agent_run = AgentRun.claim_next_queued_run(target_id: agent_run_id)
      return { claimed: false } unless agent_run

      agent_run.update_columns(temporal_workflow_id: workflow_id)

      logger.info(
        message: "concurrency.agent_run_claimed_for_direct_start",
        agent_run_id: agent_run.id,
        workflow_id: workflow_id
      )

      { claimed: true, agent_run_id: agent_run.id }
    end
  end
end
