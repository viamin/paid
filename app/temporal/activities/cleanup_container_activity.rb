# frozen_string_literal: true

module Activities
  class CleanupContainerActivity < BaseActivity
    activity_name "CleanupContainer"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find_by(id: agent_run_id)
      unless agent_run
        logger.info(message: "agent_execution.cleanup_container_skipped_missing_run", agent_run_id: agent_run_id)
        return { agent_run_id: agent_run_id }
      end

      track_phase(agent_run_id: agent_run_id, phase_key: "cleanup_container", phase_group: "cleanup", agent_run: agent_run) do
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
