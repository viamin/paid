# frozen_string_literal: true

module Activities
  class CleanupContainerActivity < BaseActivity
    activity_name "CleanupContainer"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      track_phase(agent_run_id: agent_run_id, phase_key: "cleanup_container", phase_group: "cleanup") do
        agent_run = AgentRun.find(agent_run_id)
        agent_run.cleanup_container(force: true)

        logger.info(
          message: "agent_execution.container_cleaned",
          agent_run_id: agent_run_id
        )

        { agent_run_id: agent_run_id }
      end
    end
  end
end
