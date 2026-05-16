# frozen_string_literal: true

module Activities
  # Provisions shared service containers (PostgreSQL, Redis, etc.) needed by
  # the project. Returns environment variables for the agent container.
  #
  # When no service containers are configured for the project, attempts to
  # auto-detect required services from the repository (Gemfile, package.json,
  # config/database.yml, docker-compose.yml) and link matching account-level
  # containers. This handles the common case where a project has not been
  # through the "Detect Services" UI flow. Auto-detection is non-fatal —
  # failures are logged and the run continues without services.
  class ProvisionServicesActivity < BaseActivity
    activity_name "ProvisionServices"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      track_phase(agent_run_id: agent_run_id, phase_key: "provision_services", phase_group: "setup", agent_run: agent_run) do
        auto_link_services_if_unconfigured(agent_run.project)

        provisioner = Containers::ServiceProvisioner.new
        env_vars = provisioner.provision(agent_run, network: Containers::Provision.network_for(agent_run: agent_run))

        logger.info(
          message: "agent_execution.services_provisioned",
          agent_run_id: agent_run_id,
          service_count: agent_run.service_container_ids.size
        )

        { agent_run_id: agent_run_id, service_environment: env_vars }
      end
    end

    private

    # When a project has no service containers linked, attempt to auto-detect
    # required services from the repository (Gemfile, package.json, etc.) and
    # link any matching account-level containers. This ensures agent runs have
    # access to services like PostgreSQL without requiring manual UI configuration.
    #
    # Non-fatal: failures are logged and do not block the agent run.
    def auto_link_services_if_unconfigured(project)
      return if project.service_containers.any?

      result = Projects::DetectServices.call(project: project)
      return if result.detected.empty?

      added = result.apply(project)

      project.service_containers.reset if result.matched.any?
      if added.any?
        logger.info(
          message: "agent_execution.service_containers_auto_linked",
          project_id: project.id,
          services: added
        )
      end

      if result.unmatched.any?
        logger.warn(
          message: "agent_execution.service_containers_unmatched",
          project_id: project.id,
          needed: result.unmatched.map { |d| d[:service] },
          hint: "Create service containers in the account admin UI for the listed services."
        )
      end
    rescue => e
      logger.warn(
        message: "agent_execution.auto_link_services_failed",
        project_id: project.id,
        error_class: e.class.name,
        error: e.message
      )
    end
  end
end
