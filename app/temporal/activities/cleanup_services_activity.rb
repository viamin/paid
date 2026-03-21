# frozen_string_literal: true

module Activities
  # Cleans up service containers after an agent run completes.
  # Best-effort: stops containers only if no other active runs need them.
  class CleanupServicesActivity < BaseActivity
    activity_name "CleanupServices"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      track_phase(agent_run_id: agent_run_id, phase_key: "cleanup_services", phase_group: "cleanup", agent_run: agent_run) do
        provisioner = Containers::ServiceProvisioner.new
        provisioner.cleanup(agent_run)

        logger.info(
          message: "agent_execution.services_cleaned",
          agent_run_id: agent_run_id
        )

        { agent_run_id: agent_run_id }
      end
    end
  end
end
