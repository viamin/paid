# frozen_string_literal: true

require "docker-api"
require "securerandom"

module AgentRuns
  # Provisions the headless browser container that the playwright-mcp MCP server
  # connects to during interactive agent verification (RDR-045 Phase 2).
  #
  # The browser container (ghcr.io/browserless/chromium) is created with a
  # per-run container name on the agent run's Docker network and exposes a
  # stable Docker DNS alias, `paid-screenshot-browser`. The playwright-mcp npx
  # MCP server reaches the browser through that alias at :3000.
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
  # `mcp_sidecar_container_ids` only after the MCP provisioner re-runs. That
  # ordering matters because `Containers::McpProvisioner#provision` clears the
  # current sidecar list before rebuilding it; recording the browser earlier
  # would make it look stale and get it deleted before the agent starts.
  #
  # Idempotency: when this agent run's browser container already exists on the
  # expected network, it is adopted rather than recreated. Re-running with the
  # same definition does not duplicate work.
  class Verification
    class Error < StandardError; end

    BROWSER_IMAGE = Screenshots::ContainerCapture::CHROME_IMAGE
    BROWSER_HOSTNAME = Screenshots::ContainerCapture::CHROME_ALIAS
    BROWSER_CDP_PORT = 3000
    CDP_URL = Screenshots::ContainerCapture::CHROME_URL
    BROWSER_CONTAINER_NAME_PREFIX = "paid-verification-browser".freeze
    BROWSER_LABEL = "paid.verification_browser".freeze
    AGENT_RUN_LABEL = "paid.agent_run_id".freeze

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
      reprovision_keeping_browser!(result.container_id)

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
    # definition is materialized into a stdio server spec on the agent run.
    # `mcp_provisioned_servers` is what `RunAgentActivity` reads when wiring
    # MCP servers into the agent's harness, so this update must happen before
    # the agent starts.
    def republish_provisioned_servers!
      Containers::McpProvisioner.new.provision(@agent_run, network: @network)
    end

    # Re-runs the MCP provisioner while keeping the verification browser out of
    # `mcp_sidecar_container_ids` for the duration of the call.
    # `McpProvisioner#provision` clears that list (and deletes those containers)
    # before rebuilding it, so a browser recorded beforehand would be torn down
    # as stale and the playwright-mcp `CDP_URL` would resolve to a dead
    # container. Tracking is restored in `ensure` so a failed reprovision still
    # leaves the browser recorded for cleanup instead of leaking until the
    # orphan janitor reaps it.
    def reprovision_keeping_browser!(browser_container_id)
      untrack_sidecar_id(browser_container_id)
      republish_provisioned_servers!
    ensure
      track_sidecar_id(browser_container_id)
    end

    def adopt_or_create_browser
      container = Containers.backend.get_container(browser_container_name)
      return container if browser_container_matches_run?(container)

      remove_browser(container)
      create_browser
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
        "name" => browser_container_name,
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
          AGENT_RUN_LABEL => @agent_run.id.to_s
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

    def untrack_sidecar_id(container_id)
      existing = Array(@agent_run.mcp_sidecar_container_ids)
      return unless existing.include?(container_id)

      @agent_run.update_columns(mcp_sidecar_container_ids: existing - [ container_id ])
    end

    def browser_container_name
      "#{BROWSER_CONTAINER_NAME_PREFIX}-run#{@agent_run.id}"
    end

    def browser_container_matches_run?(container)
      labels = container_config(container).fetch("Labels", {})
      labels[BROWSER_LABEL] == "true" &&
        labels[AGENT_RUN_LABEL] == @agent_run.id.to_s &&
        container_attached_to_network?(container)
    end

    def container_attached_to_network?(container)
      networks = container_networks(container)
      networks.key?(@network)
    end

    def container_config(container)
      container.json.fetch("Config", {})
    rescue Docker::Error::DockerError
      {}
    end

    def container_networks(container)
      container.json.dig("NetworkSettings", "Networks") || {}
    rescue Docker::Error::DockerError
      {}
    end

    def remove_browser(container)
      Containers.backend.stop_container(container, timeout: 10)
    rescue Docker::Error::NotFoundError, Docker::Error::ClientError, Docker::Error::ServerError
      # Already stopped, gone, or a transient daemon error — proceed to force-delete.
    ensure
      begin
        Containers.backend.delete_container(container, force: true, v: true)
      rescue Docker::Error::NotFoundError
        # Already removed.
      rescue Docker::Error::DockerError => e
        raise Error, "Failed to replace verification browser container: #{e.message}"
      end
    end

    def log_info(message, **metadata)
      @logger.info(message: message, **metadata)
    end
  end
end
