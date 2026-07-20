# frozen_string_literal: true

require "docker-api"
module Containers
  # Provisions MCP (Model Context Protocol) servers for agent runs.
  #
  # Handles two types of MCP server definitions from the run's snapshot:
  #
  # 1. **npx** — stdio-based servers that run inside the agent container.
  #    These are materialized as command specs for the execution layer;
  #    no sidecar container is created.
  #
  # 2. **docker_image** — sidecar containers provisioned on the same Docker
  #    network as the agent container. Each gets a stable hostname so the
  #    agent can reach it at `http://<hostname>:<port>/sse`.
  #
  # Sidecar container IDs are tracked on `AgentRun#mcp_sidecar_container_ids`
  # for cleanup and auditability.
  #
  # @example Provision MCP servers for a run
  #   provisioner = Containers::McpProvisioner.new
  #   result = provisioner.provision(agent_run, network: "paid_agent")
  #   result[:stdio_servers]  # => [{ "name" => "...", "command" => "@modelcontextprotocol/server-github", ... }]
  #   result[:url_servers]    # => [{ "name" => "...", "url" => "http://..." }]
  #
  # @example Clean up after run
  #   provisioner.cleanup(agent_run)
  class McpProvisioner
    class Error < StandardError; end

    HEALTH_CHECK_TIMEOUT = 30
    HEALTH_CHECK_INTERVAL = 1
    CONTAINER_NAME_PREFIX = "paid-mcp"
    DEFAULT_PORT = 3000
    MAX_NAME_LENGTH = 63

    RESOURCE_LIMITS = {
      memory: 1 * 1024 * 1024 * 1024,
      cpu_quota: 100_000,
      pids_limit: 200
    }.freeze

    def self.materialize_npx_server(definition)
      server = {
        "name" => definition["name"],
        "transport" => "stdio",
        "command" => definition["command"],
        "args" => definition.fetch("args", [])
      }
      server["env"] = definition["env"] if definition["env"].present?
      server
    end

    # Provisions MCP servers from the agent run's snapshot.
    #
    # @param agent_run [AgentRun] the run whose mcp_server_snapshot to provision
    # @param network [String] Docker network name for sidecar containers
    # @return [Hash] with :stdio_servers and :url_servers arrays
    def provision(agent_run, network: NetworkPolicy::NETWORK_NAME)
      snapshot = agent_run.mcp_server_snapshot
      sidecar_ids = []
      preserved_sidecar_ids = []

      # Clean up stale sidecars from a prior failed attempt to avoid leaks.
      stale_ids = Array(agent_run.mcp_sidecar_container_ids)
      preserved_sidecar_ids, stale_ids = partition_preserved_sidecar_ids(agent_run, stale_ids)
      cleanup_containers(stale_ids) if stale_ids.present?

      if snapshot.blank?
        agent_run.update!(
          mcp_provisioned_servers: { "stdio_servers" => [], "url_servers" => [] },
          mcp_sidecar_container_ids: preserved_sidecar_ids
        )
        return { stdio_servers: [], url_servers: [] }
      end

      @network = network
      stdio_servers = []
      url_servers = []

      snapshot.each do |definition|
        case definition["install_type"]
        when "npx"
          stdio_servers << materialize_npx_server(definition)
        when "docker_image"
          result = provision_docker_sidecar(agent_run, definition)
          url_servers << result[:server]
          sidecar_ids << result[:container_id]
        end
      end

      agent_run.update!(
        mcp_provisioned_servers: { "stdio_servers" => stdio_servers, "url_servers" => url_servers },
        mcp_sidecar_container_ids: preserved_sidecar_ids + sidecar_ids
      )

      log_info("mcp_provisioner.provisioned",
        agent_run_id: agent_run.id,
        stdio_count: stdio_servers.size,
        sidecar_count: url_servers.size)

      { stdio_servers: stdio_servers, url_servers: url_servers }
    rescue Error
      cleanup_containers(sidecar_ids)
      raise
    rescue => e
      cleanup_containers(sidecar_ids)
      raise Error, "MCP provisioning failed: #{e.message}"
    end

    # Removes all MCP sidecar containers for the given agent run.
    #
    # @param agent_run [AgentRun] the run to clean up
    def cleanup(agent_run)
      container_ids = agent_run.mcp_sidecar_container_ids
      return if container_ids.blank?

      cleanup_containers(container_ids)
      agent_run.update_columns(mcp_sidecar_container_ids: [])

      log_info("mcp_provisioner.cleaned_up",
        agent_run_id: agent_run.id,
        container_count: container_ids.size)
    end

    private

    # Materializes an npx MCP definition into a stdio server spec.
    # The agent execution layer will launch this command inside the container.
    def materialize_npx_server(definition)
      self.class.materialize_npx_server(definition)
    end

    # Provisions a Docker sidecar container for a docker_image MCP definition.
    # Only SSE transport is supported for docker_image definitions — the agent
    # reaches the sidecar over HTTP.
    #
    # @return [Hash] with :server (connection spec) and :container_id
    def provision_docker_sidecar(agent_run, definition)
      transport = definition["transport"]
      unless transport == "sse"
        raise Error, "docker_image MCP server #{definition["name"].inspect} requires transport \"sse\", got #{transport.inspect}"
      end

      NetworkPolicy.ensure_network!(network: @network, backend: Containers.backend)

      image = definition["image"]
      name = definition["name"]
      hostname = sidecar_hostname(agent_run, name)
      port = resolve_port(definition)
      env = definition.fetch("env", {})

      pull_image(image)
      container = adopt_or_create_sidecar(
        image: image,
        hostname: hostname,
        port: port,
        env: env,
        agent_run: agent_run
      )

      begin
        Containers.backend.start_container(container) unless container_running?(container)
        wait_for_health!(container, hostname, port)
      rescue => e
        remove_container(container)
        raise Error, "Failed to start MCP sidecar #{name}: #{e.message}"
      end

      url = "http://#{hostname}:#{port}/sse"

      log_info("mcp_provisioner.sidecar_started",
        agent_run_id: agent_run.id,
        name: name,
        image: image,
        container_id: container.id,
        url: url)

      server = {
        "name" => name,
        "transport" => "sse",
        "url" => url
      }
      { server: server, container_id: container.id }
    end

    # Adopts an existing sidecar container (from a prior attempt) or creates
    # a new one. This makes provisioning idempotent across activity retries.
    def adopt_or_create_sidecar(image:, hostname:, port:, env:, agent_run:)
      Containers.backend.get_container(hostname)
    rescue Docker::Error::NotFoundError
      create_sidecar_container(image: image, hostname: hostname, port: port, env: env, agent_run: agent_run)
    end

    def container_running?(container)
      state = container.json.dig("State", "Running")
      state == true
    rescue Docker::Error::DockerError
      false
    end

    def create_sidecar_container(image:, hostname:, port:, env:, agent_run:)
      Containers.backend.create_container(
        "Image" => image,
        "name" => hostname,
        "Env" => env.map { |k, v| "#{k}=#{v}" },
        "ExposedPorts" => { "#{port}/tcp" => {} },
        "HostConfig" => {
          "NetworkMode" => @network,
          "Memory" => RESOURCE_LIMITS[:memory],
          "MemorySwap" => RESOURCE_LIMITS[:memory],
          "CpuPeriod" => 100_000,
          "CpuQuota" => RESOURCE_LIMITS[:cpu_quota],
          "PidsLimit" => RESOURCE_LIMITS[:pids_limit]
        },
        "NetworkingConfig" => {
          "EndpointsConfig" => {
            @network => {
              "Aliases" => [ hostname ]
            }
          }
        },
        "Labels" => {
          "paid.mcp_sidecar" => "true",
          "paid.agent_run_id" => agent_run.id.to_s
        }
      )
    rescue Docker::Error::DockerError => e
      raise Error, "Failed to create MCP sidecar container: #{e.message}"
    end

    def pull_image(image)
      Containers.backend.pull_image("fromImage" => image)
    rescue Docker::Error::NotFoundError
      raise Error, "MCP server image not found: #{image}"
    rescue Docker::Error::DockerError => e
      raise Error, "Failed to pull MCP server image #{image}: #{e.message}"
    end

    def wait_for_health!(container, hostname, port)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HEALTH_CHECK_TIMEOUT

      loop do
        return if Containers::TcpHealthProbe.open?(backend: Containers.backend, container: container, host: hostname, port: port)

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise Error, "Health check timeout for MCP sidecar #{hostname}:#{port}"
        end

        sleep HEALTH_CHECK_INTERVAL
      end
    end

    def sidecar_hostname(agent_run, name)
      suffix = "run#{agent_run.id}"
      budget = [ MAX_NAME_LENGTH - CONTAINER_NAME_PREFIX.length - suffix.length - 2, 1 ].max
      segment = sanitize_name(name).first(budget).delete_suffix("-").presence || "mcp"
      [ CONTAINER_NAME_PREFIX, segment, suffix ].join("-")
    end

    def sanitize_name(name)
      name.to_s.downcase
        .gsub(/[^a-z0-9-]/, "-")
        .gsub(/-+/, "-")
        .delete_prefix("-")
        .presence || "mcp"
    end

    VALID_PORT_RANGE = (1..65535).freeze

    def resolve_port(definition)
      metadata = definition.fetch("metadata", {})
      port = metadata["port"]&.to_i || DEFAULT_PORT

      unless VALID_PORT_RANGE.cover?(port)
        raise Error, "Invalid port #{port} for MCP server #{definition["name"].inspect}; must be 1..65535"
      end

      port
    end

    def cleanup_containers(container_ids)
      container_ids.each do |cid|
        remove_container_by_id(cid)
      end
    end

    def partition_preserved_sidecar_ids(agent_run, container_ids)
      container_ids.partition do |container_id|
        preserve_sidecar_during_reprovision?(agent_run, container_id)
      end
    end

    def preserve_sidecar_during_reprovision?(agent_run, container_id)
      container = Containers.backend.get_container(container_id)
      labels = container.json.fetch("Config", {}).fetch("Labels", {})

      labels[AgentRuns::Verification::BROWSER_LABEL] == "true" &&
        labels[AgentRuns::Verification::AGENT_RUN_LABEL] == agent_run.id.to_s
    rescue Docker::Error::NotFoundError
      false
    rescue Docker::Error::DockerError => e
      log_warn("mcp_provisioner.sidecar_inspection_failed",
        agent_run_id: agent_run.id,
        container_id: container_id,
        error: e.message)
      true
    end

    def remove_container(container)
      Containers.backend.stop_container(container, timeout: 10)
    rescue Docker::Error::NotFoundError, Docker::Error::ClientError, Docker::Error::ServerError
      # Already stopped or daemon error — proceed to force-delete
    ensure
      begin
        Containers.backend.delete_container(container, force: true, v: true)
      rescue Docker::Error::NotFoundError
        # Already gone
      rescue Docker::Error::DockerError => e
        log_warn("mcp_provisioner.container_delete_failed",
          container_id: container.id, error: e.message)
      end
    end

    def remove_container_by_id(container_id)
      container = Containers.backend.get_container(container_id)
      begin
        Containers.backend.stop_container(container, timeout: 10)
      rescue Docker::Error::NotFoundError, Docker::Error::ClientError
        # Already stopped
      end
    rescue Docker::Error::NotFoundError
      # Already gone — nothing to delete
    rescue Docker::Error::DockerError => e
      log_warn("mcp_provisioner.cleanup_failed",
        container_id: container_id, error: e.message)
    ensure
      if container
        begin
          Containers.backend.delete_container(container, force: true, v: true)
        rescue Docker::Error::NotFoundError
          # Already gone
        rescue Docker::Error::DockerError => e
          log_warn("mcp_provisioner.container_delete_failed",
            container_id: container_id, error: e.message)
        end
      end
    end

    def log_info(message, **metadata)
      Rails.logger.info(message: message, **metadata)
    end

    def log_warn(message, **metadata)
      Rails.logger.warn(message: message, **metadata)
    end
  end
end
