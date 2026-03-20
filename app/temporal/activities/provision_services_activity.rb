# frozen_string_literal: true

module Activities
  # Provisions shared service containers (PostgreSQL, Redis, etc.) needed by
  # the project. Returns environment variables for the agent container.
  #
  # Skipped if the project has no service containers configured.
  class ProvisionServicesActivity < BaseActivity
    activity_name "ProvisionServices"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      track_phase(agent_run_id: agent_run_id, phase_key: "provision_services", phase_group: "setup", agent_run: agent_run) do
        provisioner = Containers::ServiceProvisioner.new
        env_vars = provisioner.provision(agent_run, network: NetworkPolicy.agent_network)

        logger.info(
          message: "agent_execution.services_provisioned",
          agent_run_id: agent_run_id,
          service_count: agent_run.service_container_ids.size
        )

        { agent_run_id: agent_run_id, service_environment: env_vars }
      end
    end
  end
end
