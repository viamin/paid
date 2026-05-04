# frozen_string_literal: true

module Activities
  # Provisions MCP (Model Context Protocol) servers for an agent run.
  #
  # Materializes npx definitions as stdio server specs and provisions
  # docker_image definitions as sidecar containers on the agent network.
  #
  # Skipped when the run's mcp_server_snapshot is empty.
  class ProvisionMcpServersActivity < BaseActivity
    activity_name "ProvisionMcpServers"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      track_phase(agent_run_id: agent_run_id, phase_key: "provision_mcp_servers", phase_group: "setup", agent_run: agent_run) do
        provisioner = Containers::McpProvisioner.new
        result = provisioner.provision(
          agent_run,
          network: Containers::Provision.network_for(agent_run: agent_run)
        )

        logger.info(
          message: "agent_execution.mcp_servers_provisioned",
          agent_run_id: agent_run_id,
          stdio_count: result[:stdio_servers].size,
          sidecar_count: result[:url_servers].size
        )

        {
          agent_run_id: agent_run_id,
          stdio_servers: result[:stdio_servers],
          url_servers: result[:url_servers]
        }
      rescue Containers::McpProvisioner::Error => e
        raise Temporalio::Error::ApplicationError.new(
          e.message,
          type: "McpProvisioningFailed",
          non_retryable: non_retryable_provisioning_error?(e)
        )
      end
    end

    private

    # Configuration errors (invalid port, wrong transport, missing image) are
    # non-retryable — retrying won't fix them. Transient Docker/network errors
    # benefit from Temporal's default retry policy.
    NON_RETRYABLE_PATTERNS = [
      /invalid port/i,
      /requires transport/i,
      /image not found/i
    ].freeze

    def non_retryable_provisioning_error?(error)
      NON_RETRYABLE_PATTERNS.any? { |pattern| pattern.match?(error.message) }
    end
  end
end
