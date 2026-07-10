# frozen_string_literal: true

require "docker-api"
require "securerandom"

module AgentRuns
  # Provisions the headless browser container that the playwright-mcp MCP server
  # connects to during interactive agent verification (RDR-045 Phase 2).
  #
  # The browser container (ghcr.io/browserless/chromium) is created on the
  # agent run's Docker network with the well-known alias `paid-screenshot-browser`
  # and exposes a CDP WebSocket endpoint at :3000. The playwright-mcp npx MCP
  # server reaches the browser via Docker DNS by hostname.
  #
  # The MCP definition itself is attached by `Project#ensure_playwright_mcp_definition!`,
  # which is invoked here so the definition is in place even for legacy
  # projects that enabled verification before the MCP wiring landed. The
  # snapshot of MCP servers on the agent run is updated to include the new
  # definition, then `Containers::McpProvisioner` is re-run to materialize
  # the stdio server spec with `CDP_URL` env pointing at the browser. This
  # re-uses the same plumbing that the workflow's MCP-provisioning activity
  # uses, so the agent sees playwright-mcp in its MCP server list once the
  # activity completes.
  #
  # The browser container's ID is recorded on the agent run via
  # `mcp_sidecar_container_ids` so the existing `CleanupMcpServersActivity`
  # tears it down alongside any other MCP sidecars. This reuses the existing
  # cleanup code path and keeps capacity accounting accurate (see
  # `Capacity::DockerContainerInventory`).
  #
  # Idempotency: when a browser container with the expected hostname already
  # exists (e.g. from a prior failed attempt), it is adopted rather than
  # recreated. Re-running with the same definition does not duplicate work.
  class Verification
    class Error < StandardError; end

    BROWSER_IMAGE = Screenshots::ContainerCapture::CHROME_IMAGE
    BROWSER_HOSTNAME = Screenshots::ContainerCapture::CHROME_ALIAS
    BROWSER_CDP_PORT = 3000
    CDP_URL = Screenshots::ContainerCapture::CHROME_URL
    BROWSER_LABEL = "paid.verification_browser".freeze

    MEMORY_BYTES = 1 * 1024 * 1024 * 1024
    CPU_QUOTA = 100_000
    PIDS_LIMIT = 200

    HEALTH_CHECK_TIMEOUT = 30
    HEALTH_CHECK_INTERVAL = 1

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, network:, logger: Rails.logger)
      @agent_run = agent_run
      @network = network
      @logger = logger
    end

    def call
      attach_playwright_definition!
      synchronize_snapshot!
      result = provision_browser_container!
      republish_provisioned_servers!

      log_info("agent_runs.verification.completed",
        agent_run_id: @agent_run.id,
        container_id: result.container_id,
        hostname: BROWSER_HOSTNAME,
        cdp_url: CDP_URL)

      result
    end

    Result = Struct.new(:status, :container_id, :hostname, :cdp_url, keyword_init: true) do
      def success? = status == "provisioned"
    end

    private

    # Ensures the playwright-mcp MCP definition exists for the project's
    # account and is attached to the project. Idempotent.
    def attach_playwright_definition!
      @agent_run.project.ensure_playwright_mcp_definition!
    end

    # Rebuilds the agent run's MCP server snapshot from the project's current
    # enabled definitions and persists it. AgentRun marks the creation-time
    # snapshot as readonly, so persistence uses `update_all` to bypass the
    # instance-level guard — mirroring the pattern used by
    # `MarketplaceEntries::McpSnapshotSync`.
    def synchronize_snapshot!
      definitions = @agent_run.project.mcp_server_definitions.enabled.order(:id)
      new_snapshot = definitions.map(&:to_snapshot)
      return if Array(@agent_run.mcp_server_snapshot) == new_snapshot

      AgentRun.where(id: @agent_run.id).update_all(mcp_server_snapshot: new_snapshot)
      @agent_run.reload
    end

    def provision_browser_container!
      NetworkPolicy.ensure_network!(network: @network, backend: Containers.backend)

      container = adopt_or_create_browser
      Containers.backend.start_container(container) unless container_running?(container)
      wait_for_health!(container)
      track_sidecar_id(container.id)

      Result.new(
        status: "provisioned",
        container_id: container.id,
        hostname: BROWSER_HOSTNAME,
        cdp_url: CDP_URL
      )
    rescue Docker::Error::DockerError => e
      raise Error, "Failed to provision verification browser container: #{e.message}"
    end

    # Re-runs the MCP provisioner so the freshly-snapshotted playwright-mcp
    # definition is materialized into an stdio server spec on the agent run.
    # `mcp_provisioned_servers` is what `RunAgentActivity` reads when wiring
    # MCP servers into the agent's harness, so this update must happen before
    # the agent starts.
    def republish_provisioned_servers!
      Containers::McpProvisioner.new.provision(@agent_run, network: @network)
    end

    def adopt_or_create_browser
      Containers.backend.get_container(BROWSER_HOSTNAME)
    rescue Docker::Error::NotFoundError
      create_browser
    end

    def container_running?(container)
      state = container.json.dig("State", "Running")
      state == true
    rescue Docker::Error::DockerError
      false
    end

    def create_browser
      Containers.backend.create_container(
        "Image" => BROWSER_IMAGE,
        "name" => BROWSER_HOSTNAME,
        "ExposedPorts" => { "#{BROWSER_CDP_PORT}/tcp" => {} },
        "HostConfig" => {
          "NetworkMode" => @network,
          "Memory" => MEMORY_BYTES,
          "MemorySwap" => MEMORY_BYTES,
          "CpuPeriod" => 100_000,
          "CpuQuota" => CPU_QUOTA,
          "PidsLimit" => PIDS_LIMIT
        },
        "NetworkingConfig" => {
          "EndpointsConfig" => {
            @network => {
              "Aliases" => [ BROWSER_HOSTNAME ]
            }
          }
        },
        "Labels" => {
          "paid.verification_browser" => "true",
          "paid.agent_run_id" => @agent_run.id.to_s
        }
      )
    rescue Docker::Error::DockerError => e
      raise Error, "Failed to create verification browser container: #{e.message}"
    end

    def wait_for_health!(container)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HEALTH_CHECK_TIMEOUT

      loop do
        return if Containers::TcpHealthProbe.open?(
          backend: Containers.backend,
          container: container,
          host: BROWSER_HOSTNAME,
          port: BROWSER_CDP_PORT
        )

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise Error, "Verification browser health check timed out at #{BROWSER_HOSTNAME}:#{BROWSER_CDP_PORT}"
        end

        sleep HEALTH_CHECK_INTERVAL
      end
    end

    def track_sidecar_id(container_id)
      existing = Array(@agent_run.mcp_sidecar_container_ids)
      return if existing.include?(container_id)

      @agent_run.update_columns(mcp_sidecar_container_ids: existing + [ container_id ])
    end

    def log_info(message, **metadata)
      @logger.info(message: message, **metadata)
    end
  end
end
