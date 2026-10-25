# frozen_string_literal: true

require "docker-api"
module Containers
  # Provisions MCP (Model Context Protocol) servers and hardened marketplace
  # tool sidecars for agent runs.
  #
  # Handles three types of definitions from the run's snapshot:
  #
  # 1. **npx** — stdio-based MCP servers that run inside the agent container.
  #    These are materialized as command specs for the execution layer;
  #    no sidecar container is created.
  #
  # 2. **docker_image** — MCP sidecar containers provisioned on the same Docker
  #    network as the agent container. Each gets a stable hostname so the
  #    agent can reach it at `http://<hostname>:<port>/sse`.
  #
  # 3. **tool** — hardened marketplace tool sidecar containers, built through
  #    the `Containers::ServiceProvisioner` hardening profile path
  #    (capabilities dropped, `no-new-privileges`, image-family profile or
  #    default profile). Tools are plain TCP/HTTP endpoints — they are
  #    registered on the same per-run DNS alias pattern as MCP sidecars but
  #    never appear in the agent's MCP server list.
  #
  # Sidecar container IDs are persisted on `AgentRun#mcp_sidecar_container_ids`
  # (MCP url servers) and `AgentRun#tool_sidecar_container_ids` (tools) so
  # cleanup and auditability work uniformly across retries.
  #
  # @example Provision MCP servers and tools for a run
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
    TOOL_CONTAINER_NAME_PREFIX = "paid-tool"
    DEFAULT_PORT = 3000
    TOOL_DEFAULT_PORT = 8080
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

    # Provisions MCP servers and hardened tool sidecars from the agent run's
    # snapshot.
    #
    # @param agent_run [AgentRun] the run whose mcp_server_snapshot to provision
    # @param network [String] Docker network name for sidecar containers
    # @return [Hash] with :stdio_servers and :url_servers arrays
    def provision(agent_run, network: NetworkPolicy::NETWORK_NAME)
      snapshot = agent_run.mcp_server_snapshot
      tool_snapshot = agent_run.tool_sidecar_snapshot
      sidecar_ids = []
      tool_ids = []
      tool_endpoints = []
      preserved_sidecar_ids = []
      stale_tool_ids = []

      # Clean up stale sidecars from a prior failed attempt to avoid leaks.
      stale_ids = Array(agent_run.mcp_sidecar_container_ids)
      preserved_sidecar_ids, stale_ids = partition_preserved_sidecar_ids(agent_run, stale_ids)
      cleanup_containers(stale_ids) if stale_ids.present?

      stale_tool_ids = Array(agent_run.tool_sidecar_container_ids)

      if snapshot.blank? && tool_snapshot.blank?
        cleanup_containers(stale_tool_ids) if stale_tool_ids.present?
        agent_run.update!(
          mcp_provisioned_servers: { "stdio_servers" => [], "url_servers" => [] },
          mcp_sidecar_container_ids: preserved_sidecar_ids,
          tool_sidecar_container_ids: [],
          tool_sidecar_endpoints: []
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

      tool_snapshot.each do |definition|
        result = provision_tool_sidecar(agent_run, definition)
        next unless result

        tool_ids << result[:container_id]
        tool_endpoints << result[:endpoint]
      end

      cleanup_containers(stale_tool_ids - tool_ids)

      agent_run.update!(
        mcp_provisioned_servers: { "stdio_servers" => stdio_servers, "url_servers" => url_servers },
        mcp_sidecar_container_ids: preserved_sidecar_ids + sidecar_ids,
        tool_sidecar_container_ids: tool_ids,
        tool_sidecar_endpoints: tool_endpoints
      )

      log_info("mcp_provisioner.provisioned",
        agent_run_id: agent_run.id,
        stdio_count: stdio_servers.size,
        sidecar_count: url_servers.size,
        tool_count: tool_ids.size)

      { stdio_servers: stdio_servers, url_servers: url_servers }
    rescue Error
      cleanup_containers(sidecar_ids)
      cleanup_containers(tool_ids)
      cleanup_containers(stale_tool_ids - tool_ids)
      agent_run.update_columns(tool_sidecar_container_ids: [], tool_sidecar_endpoints: [])
      raise
    rescue Containers::ServiceProvisioner::Error => e
      cleanup_containers(sidecar_ids)
      cleanup_containers(tool_ids)
      cleanup_containers(stale_tool_ids - tool_ids)
      agent_run.update_columns(tool_sidecar_container_ids: [], tool_sidecar_endpoints: [])
      raise Error, "MCP provisioning failed: #{e.message}"
    rescue => e
      cleanup_containers(sidecar_ids)
      cleanup_containers(tool_ids)
      cleanup_containers(stale_tool_ids - tool_ids)
      agent_run.update_columns(tool_sidecar_container_ids: [], tool_sidecar_endpoints: [])
      raise Error, "MCP provisioning failed: #{e.message}"
    end

    # Removes all MCP and marketplace tool sidecar containers for the given
    # agent run. Both kinds share the run lifecycle cleanup entrypoint.
    #
    # @param agent_run [AgentRun] the run to clean up
    def cleanup(agent_run)
      container_ids = agent_run.mcp_sidecar_container_ids
      cleanup_containers(container_ids) if container_ids.present?
      agent_run.update_columns(mcp_sidecar_container_ids: []) if container_ids.present?

      cleanup_tool_sidecars(agent_run)

      return if container_ids.blank?

      log_info("mcp_provisioner.cleaned_up", agent_run_id: agent_run.id, container_count: container_ids.size)
    end

    # Removes all hardened marketplace tool sidecar containers for the given
    # agent run.
    #
    # @param agent_run [AgentRun] the run to clean up
    # @spec TOOL-SIDECAR-005
    # @spec TOOL-SIDECAR-007
    def cleanup_tool_sidecars(agent_run)
      container_ids = agent_run.tool_sidecar_container_ids
      endpoints = agent_run.tool_sidecar_endpoints
      return if container_ids.blank? && endpoints.blank?

      cleanup_containers(container_ids) if container_ids.present?
      agent_run.update_columns(tool_sidecar_container_ids: [], tool_sidecar_endpoints: [])

      log_info("container_manager.tool_sidecars_cleaned_up",
        agent_run_id: agent_run.id,
        container_count: Array(container_ids).size)
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

      Containers::Provision.ensure_network!(network: @network, backend: Containers.backend)

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

    # Provisions a hardened marketplace tool sidecar for a `"tool"`
    # install_type definition. Validates the image against the account's
    # operator allowlist (fail closed) and builds the container through the
    # `Containers::ServiceProvisioner` hardening profile path so capabilities
    # are dropped, `no-new-privileges` is applied, and the image-family
    # `HARDENING_PROFILES` entry (or the default profile) shapes the runtime
    # user, root filesystem, tmpfs mounts, and additional capabilities.
    #
    # Returns +nil+ when the rollout guard flag is off — matching tool
    # definitions still resolve into the snapshot but never provision or
    # persist container IDs while the flag is disabled.
    #
    # @return [Hash, nil] with :container_id and :endpoint, or nil when the flag is off
    # @spec TOOL-SIDECAR-005
    # @spec TOOL-SIDECAR-006
    # @spec TOOL-SIDECAR-007
    def provision_tool_sidecar(agent_run, definition)
      unless tool_sidecars_enabled?(agent_run)
        log_info("container_manager.tool_sidecar_skipped_flag_off",
          agent_run_id: agent_run.id,
          name: definition["name"])
        return nil
      end

      image = definition["image"]
      name = definition["name"]
      env = definition.fetch("env", {})
      port = resolve_port(definition, default_port: TOOL_DEFAULT_PORT)

      validate_tool_image_allowlisted!(agent_run, image)
      validate_tool_hardening_override!(image, env)

      Containers::Provision.ensure_network!(network: @network, backend: Containers.backend)

      hostname = tool_sidecar_hostname(agent_run, name)

      pull_tool_image(image)
      container = adopt_or_create_tool_sidecar(
        image: image,
        hostname: hostname,
        port: port,
        env: env,
        agent_run: agent_run
      )

      begin
        Containers.backend.start_container(container) unless container_running?(container)
        wait_for_tool_health!(container, hostname, port)
      rescue Error
        remove_container(container)
        raise
      rescue => e
        remove_container(container)
        raise Error, "Failed to start tool sidecar #{name}: #{e.message}"
      end

      log_info("container_manager.tool_sidecar_started",
        agent_run_id: agent_run.id,
        name: name,
        image: image,
        container_id: container.id,
        hostname: hostname,
        port: port)

      { container_id: container.id, endpoint: tool_sidecar_endpoint(name, hostname, port) }
    end

    # Returns true when the rollout guard flag enables the tool arm for the
    # run's project. When the flag is off, the `"tool"` arm in #provision
    # returns nil and never creates a container.
    # @spec TOOL-SIDECAR-002
    def tool_sidecars_enabled?(agent_run)
      FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)
    end

    # Image gate (fail closed): raises when the image is not in the union of
    # `allowed_service_images` configured on every admin/owner
    # `UserSetting` for the run's account, matching the surface used by
    # `ServiceContainer#image_in_allowlist`.
    # @spec TOOL-SIDECAR-006
    def validate_tool_image_allowlisted!(agent_run, image)
      return if account_allowed_images_for(agent_run).include?(image)

      raise Error, "Image #{image.inspect} is not in the allowed service images list for this account"
    end

    # @spec TOOL-SIDECAR-006
    def account_allowed_images_for(agent_run)
      project = agent_run.project
      return [] unless project

      self.class.allowed_images_for_project(project)
    end

    # Union of `allowed_service_images` configured on every admin/owner
    # `UserSetting` for the project's account — the same allowlist surface the
    # image gate enforces at provisioning time. Public so capability-aware
    # surfaces (e.g. Prerequisites::CapabilityReport) can report the current
    # policy without duplicating the query.
    # @spec TOOL-SIDECAR-006
    def self.allowed_images_for_project(project)
      admin_user_ids = AccountMembership
        .where(account_id: project.account_id, role: [ :admin, :owner ])
        .select(:user_id)

      UserSetting.where(user_id: admin_user_ids)
        .pluck(:allowed_service_images)
        .compact
        .flatten
        .uniq
    end

    # Override gate (fail closed): a `PAID_SERVICE_HARDENING` payload on the
    # tool definition is rejected the same way a service container override is.
    # Built-in image families (`HARDENING_PROFILES`) refuse `readonly_rootfs`
    # and `user` overrides; `cap_add` is restricted to
    # `SAFE_OVERRIDE_CAPABILITIES`. The actual application happens inside
    # `Containers::ServiceProvisioner.compute_hardening_profile`; this method
    # surfaces its `Containers::ServiceProvisioner::Error` as
    # `Containers::McpProvisioner::Error` so the activity layer sees a
    # single failure shape.
    # @spec TOOL-SIDECAR-006
    def validate_tool_hardening_override!(image, env)
      Containers::ServiceProvisioner.compute_hardening_profile(image: image, env: env)
    end

    # Adopts an existing tool sidecar container (from a prior attempt) or
    # creates a new one. Mirrors the docker_image adoption path so retries
    # are idempotent.
    def adopt_or_create_tool_sidecar(image:, hostname:, port:, env:, agent_run:)
      Containers.backend.get_container(hostname)
    rescue Docker::Error::NotFoundError
      create_hardened_tool_sidecar_container(
        image: image,
        hostname: hostname,
        port: port,
        env: env,
        agent_run: agent_run
      )
    end

    # Creates a hardened tool sidecar Docker container through the
    # `Containers::ServiceProvisioner` hardening profile path:
    # `CapDrop: ["ALL"]`, `SecurityOpt: ["no-new-privileges:true"]`, the
    # image-family profile when one matches, the default profile otherwise.
    # @spec TOOL-SIDECAR-005
    def create_hardened_tool_sidecar_container(image:, hostname:, port:, env:, agent_run:)
      hardening = Containers::ServiceProvisioner.compute_hardening_profile(
        image: image,
        env: env
      )
      cap_drop = [ "ALL" ]
      cap_add = hardening[:cap_add]
      security_opt = [ "no-new-privileges:true" ]
      runtime_env = env.reject { |k, _| k == Containers::ServiceProvisioner::HARDENING_ENV_KEY }

      options = {
        "Image" => image,
        "name" => hostname,
        "Env" => runtime_env.map { |k, v| "#{k}=#{v}" },
        "ExposedPorts" => { "#{port}/tcp" => {} },
        "ReadonlyRootfs" => hardening[:readonly_rootfs],
        "CapDrop" => cap_drop,
        "CapAdd" => cap_add,
        "SecurityOpt" => security_opt,
        "HostConfig" => {
          "NetworkMode" => @network,
          "Memory" => RESOURCE_LIMITS[:memory],
          "MemorySwap" => RESOURCE_LIMITS[:memory],
          "CpuPeriod" => 100_000,
          "CpuQuota" => RESOURCE_LIMITS[:cpu_quota],
          "PidsLimit" => RESOURCE_LIMITS[:pids_limit],
          "CapDrop" => cap_drop,
          "CapAdd" => cap_add,
          "SecurityOpt" => security_opt,
          "Tmpfs" => Containers::ServiceProvisioner.docker_tmpfs_mounts(hardening[:tmpfs])
        },
        "NetworkingConfig" => {
          "EndpointsConfig" => {
            @network => {
              "Aliases" => [ hostname ]
            }
          }
        },
        "Labels" => {
          "paid.tool_sidecar" => "true",
          "paid.agent_run_id" => agent_run.id.to_s
        }
      }
      options["User"] = hardening[:user] if hardening[:user].present?

      Containers.backend.create_container(options)
    rescue Docker::Error::DockerError => e
      raise Error, "Failed to create tool sidecar container: #{e.message}"
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

    # @spec TOOL-SIDECAR-005
    def pull_tool_image(image)
      Containers.backend.pull_image("fromImage" => image)
    rescue Docker::Error::NotFoundError
      raise Error, "Tool sidecar image not found: #{image}"
    rescue Docker::Error::DockerError => e
      raise Error, "Failed to pull tool sidecar image #{image}: #{e.message}"
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

    # @spec TOOL-SIDECAR-005
    def wait_for_tool_health!(container, hostname, port)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HEALTH_CHECK_TIMEOUT

      loop do
        return if Containers::TcpHealthProbe.open?(backend: Containers.backend, container: container, host: hostname, port: port)

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise Error, "Health check timeout for tool sidecar #{hostname}:#{port}"
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

    # @spec TOOL-SIDECAR-005
    def tool_sidecar_hostname(agent_run, name)
      suffix = "run#{agent_run.id}"
      budget = [ MAX_NAME_LENGTH - TOOL_CONTAINER_NAME_PREFIX.length - suffix.length - 2, 1 ].max
      segment = sanitize_name(name, fallback: "tool").first(budget).delete_suffix("-").presence || "tool"
      [ TOOL_CONTAINER_NAME_PREFIX, segment, suffix ].join("-")
    end

    # The manifest is intentionally separate from mcp_provisioned_servers:
    # marketplace tools are plain TCP/HTTP endpoints, not MCP url servers.
    # @spec TOOL-SIDECAR-007
    def tool_sidecar_endpoint(name, hostname, port)
      {
        "name" => name,
        "hostname" => hostname,
        "port" => port,
        "url" => "http://#{hostname}:#{port}"
      }
    end

    def sanitize_name(name, fallback: "mcp")
      name.to_s.downcase
        .gsub(/[^a-z0-9-]/, "-")
        .gsub(/-+/, "-")
        .delete_prefix("-")
        .presence || fallback
    end

    VALID_PORT_RANGE = (1..65535).freeze

    def resolve_port(definition, default_port: DEFAULT_PORT)
      metadata = definition.fetch("metadata", {})
      port = metadata["port"]&.to_i || default_port

      unless VALID_PORT_RANGE.cover?(port)
        raise Error, "Invalid port #{port} for sidecar #{definition["name"].inspect}; must be 1..65535"
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
