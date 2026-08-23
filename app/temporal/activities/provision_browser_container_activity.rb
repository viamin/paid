# frozen_string_literal: true

module Activities
  # Provisions the headless browser container that powers playwright-mcp
  # during agent verification (RDR-045 Phase 2).
  # @spec LIVE-PREVIEW-002
  #
  # The browser container is created on the agent run's Docker network with
  # the well-known alias `paid-screenshot-browser`. playwright-mcp reaches it
  # at `ws://paid-screenshot-browser:3000` via Docker DNS. The container ID
  # is recorded on the agent run's `mcp_sidecar_container_ids` so the existing
  # `CleanupMcpServersActivity` tears it down at workflow end.
  #
  # Skipped for projects that have not enabled verification
  # (`Project#verification_enabled?` returns false). Returns an empty
  # `status: "skipped"` hash in that case so the workflow can proceed without
  # waiting for a browser container that will not be needed.
  #
  # The service (`AgentRuns::Verification`) defensively attaches the
  # playwright-mcp MCP server definition to the project, refreshes the
  # MCP snapshot on the agent run, and upserts the materialized stdio entry
  # in `mcp_provisioned_servers` so the agent sees playwright-mcp in its MCP
  # server list. This means legacy projects that enabled verification before
  # the MCP wiring landed still get a working setup, and users who toggle
  # verification on without re-saving the project do not end up with a
  # stranded browser container.
  class ProvisionBrowserContainerActivity < BaseActivity
    activity_name "ProvisionBrowserContainer"

    def execute(input)
      agent_run = AgentRun.find(input[:agent_run_id])

      unless agent_run.project.verification_enabled?
        logger.info(
          message: "agent_execution.verification_browser_skipped",
          agent_run_id: agent_run.id,
          project_id: agent_run.project_id,
          reason: "verification_disabled"
        )
        return { agent_run_id: agent_run.id, status: "skipped" }
      end

      track_phase(
        agent_run_id: agent_run.id,
        phase_key: "provision_browser_container",
        phase_group: "setup",
        agent_run: agent_run
      ) do
        result = with_periodic_heartbeat("provision_browser_container", agent_run_id: agent_run.id) do
          runner = ExecutionRunners.resolve_for(agent_run)
          runner.provision_browser_container(
            agent_run: agent_run,
            network: Containers::Provision.network_for(agent_run: agent_run),
            logger: logger
          )
        end

        logger.info(
          message: "agent_execution.verification_browser_provisioned",
          agent_run_id: agent_run.id,
          container_id: result.container_id,
          cdp_url: result.cdp_url
        )

        {
          agent_run_id: agent_run.id,
          status: result.status,
          container_id: result.container_id,
          cdp_url: result.cdp_url
        }
      rescue AgentRuns::Verification::Error, ArgumentError => e
        raise Temporalio::Error::ApplicationError.new(
          e.message,
          type: "VerificationBrowserProvisioningFailed",
          non_retryable: non_retryable_verification_error?(e)
        )
      end
    end

    private

    NON_RETRYABLE_PATTERNS = [
      /image not found/i,
      /reserved mcp definition name/i
    ].freeze

    def non_retryable_verification_error?(error)
      NON_RETRYABLE_PATTERNS.any? { |pattern| pattern.match?(error.message) }
    end
  end
end
