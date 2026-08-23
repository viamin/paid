# frozen_string_literal: true

require "docker-api"
require "uri"

module Containers
  # Manages Docker lifecycle for service containers (PostgreSQL, Redis, etc.)
  # that agents need for running tests and setup commands.
  #
  # == High-Level Data Flow
  #
  # 1. A project defines service containers (image, name, port) via the admin UI.
  # 2. When an agent run starts, ProvisionServicesActivity calls #provision.
  # 3. #provision records the container IDs on the agent run (for reference counting),
  #    then ensures each container is running on the agent's Docker network.
  # 4. Environment variables (DATABASE_URL, REDIS_URL, etc.) are generated from
  #    the running containers and stored on the agent run.
  # 5. The agent container receives these env vars and can connect to services
  #    by hostname (containers register DNS aliases on the shared network).
  # 6. When the agent run completes, CleanupServicesActivity calls #cleanup,
  #    which drops per-run databases and only stops containers with zero
  #    remaining active runs.
  #
  # == Key Design Decisions
  #
  # - Containers are shared across concurrent agent runs in the same project
  #   to avoid duplicate instances and reduce startup latency.
  # - Each agent run gets its own isolated database within the shared PostgreSQL
  #   container, preventing schema drift from cross-branch contamination.
  # - Reference counting (via AgentRun.service_container_ids JSONB) prevents
  #   premature cleanup while other runs still need the service.
  # - Row-level locking (with_lock) prevents race conditions during concurrent
  #   provisioning of the same service container.
  # - Three background jobs handle edge cases: metrics collection, DB/Docker
  #   status reconciliation, and orphan container cleanup.
  #
  # See RDR-020 for the full architectural decision record.
  #
  # @example Provision services for an agent run
  #   provisioner = Containers::ServiceProvisioner.new
  #   env_vars = provisioner.provision(agent_run)
  #   # => { "DATABASE_URL" => "postgres://...", "REDIS_URL" => "redis://..." }
  #
  # @example Clean up after agent run completes
  #   provisioner.cleanup(agent_run)
  class ServiceProvisioner
    class Error < StandardError; end
    class DatabaseError < Error; end

    POSTGRES_DEFAULT_ENV = {
      "POSTGRES_USER" => "agent",
      "POSTGRES_PASSWORD" => "agent",
      "POSTGRES_DB" => "agent_test"
    }.freeze

    ENV_MAPPINGS = {
      "postgres" => ->(sc, host:, db_override: nil) {
        defaults = POSTGRES_DEFAULT_ENV
        user = sc.env["POSTGRES_USER"].to_s.strip.presence || defaults["POSTGRES_USER"]
        pass = sc.env["POSTGRES_PASSWORD"].to_s.strip.presence || defaults["POSTGRES_PASSWORD"]
        db = db_override || sc.env["POSTGRES_DB"].to_s.strip.presence || defaults["POSTGRES_DB"]
        { "DATABASE_URL" => "postgres://#{user}:#{pass}@#{host}:#{sc.port}/#{db}" }
      },
      "redis" => ->(sc, host:, **) {
        { "REDIS_URL" => "redis://#{host}:#{sc.port}" }
      },
      "selenium" => ->(sc, host:, **) {
        { "SELENIUM_URL" => "http://#{host}:#{sc.port}" }
      },
      "chromium" => ->(sc, host:, **) {
        { "SELENIUM_URL" => "http://#{host}:#{sc.port}" }
      }
    }.freeze

    HEALTH_CHECK_TIMEOUT = 30
    HEALTH_CHECK_INTERVAL = 1

    # Default resource limits per image pattern. Keys are matched against the
    # image name with String#include?. The first match wins.
    # Limits mirror the agent container pattern (Memory, MemorySwap equal = no swap).
    RESOURCE_LIMITS = {
      "postgres" => { memory: 2 * 1024 * 1024 * 1024, cpu_quota: 100_000, pids_limit: 200 },
      "redis"    => { memory: 1 * 1024 * 1024 * 1024, cpu_quota: 100_000, pids_limit: 100 },
      "selenium" => { memory: 2 * 1024 * 1024 * 1024, cpu_quota: 200_000, pids_limit: 300 },
      "chromium" => { memory: 2 * 1024 * 1024 * 1024, cpu_quota: 200_000, pids_limit: 300 }
    }.freeze

    DEFAULT_RESOURCE_LIMITS = { memory: 1 * 1024 * 1024 * 1024, cpu_quota: 100_000, pids_limit: 200 }.freeze
    HARDENING_ENV_KEY = "PAID_SERVICE_HARDENING"
    SAFE_OVERRIDE_CAPABILITIES = [ "NET_BIND_SERVICE" ].freeze

    # @spec CONTAINER-RUNTIME-035
    # Baseline container hardening (issue #3450): every service container
    # runs with all capabilities dropped and no-new-privileges, mirroring the
    # hardening already applied to agent and chat containers
    # (Containers::Provision, Containers::ProvisionForChat). Known image
    # families get a profiled read-only root filesystem, runtime user, and
    # Tmpfs layout for the writable paths their documented entrypoint
    # actually needs, plus the minimum capabilities that entrypoint needs
    # back. Account admins can opt custom allowlisted images into the same
    # stronger shape with an override profile stored under HARDENING_ENV_KEY
    # in ServiceContainer#env. Unrecognized images without an explicit
    # override keep a writable root filesystem for compatibility with the
    # existing allowed_service_images contract while still running with
    # no-new-privileges and all capabilities dropped.
    HARDENING_PROFILES = {
      "postgres" => {
        # Tmpfs pages are accounted against the container's memcg, so the
        # combined tmpfs budget here (1 GiB + 64 MiB + 128 MiB ≈ 1.19 GiB)
        # is sized to stay well under RESOURCE_LIMITS["postgres"][:memory]
        # (2 GiB), leaving ~800 MiB of headroom for the postgres process's
        # own RSS (shared_buffers, work_mem, WAL buffers, per-connection
        # overhead) so the container isn't OOM-killed as soon as PGDATA
        # usage grows.
        readonly_rootfs: true,
        user: "postgres",
        tmpfs: {
          "/var/lib/postgresql/data" => { size: 1 * 1024 * 1024 * 1024, mode: "0700", uid: 999, gid: 999 },
          "/var/run/postgresql" => { size: 64 * 1024 * 1024, mode: "3775", uid: 999, gid: 999 },
          "/tmp" => { size: 128 * 1024 * 1024, mode: "1777" }
        },
        cap_add: [ "CHOWN", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID" ]
      },
      "redis" => {
        readonly_rootfs: true,
        user: "redis",
        tmpfs: {
          "/data" => { size: 512 * 1024 * 1024, mode: "1777", uid: 999, gid: 1000 },
          "/tmp" => { size: 64 * 1024 * 1024, mode: "1777" }
        },
        cap_add: []
      },
      "selenium" => {
        readonly_rootfs: true,
        user: "seluser",
        tmpfs: {
          "/tmp" => { size: 256 * 1024 * 1024, mode: "1777" },
          "/dev/shm" => { size: 1024 * 1024 * 1024, mode: "1777" }
        },
        cap_add: []
      },
      "chromium" => {
        readonly_rootfs: true,
        user: "seluser",
        tmpfs: {
          "/tmp" => { size: 256 * 1024 * 1024, mode: "1777" },
          "/dev/shm" => { size: 1024 * 1024 * 1024, mode: "1777" }
        },
        cap_add: []
      }
    }.freeze

    DEFAULT_HARDENING_PROFILE = {
      readonly_rootfs: false,
      user: nil,
      tmpfs: {},
      cap_add: []
    }.freeze

    HARDENING_PROFILE_MATCHERS = {
      "postgres" => ->(repository) { repository == "postgres" || repository == "library/postgres" },
      "redis" => ->(repository) { repository == "redis" || repository == "library/redis" },
      "selenium" => ->(repository) { repository.start_with?("selenium/") && !repository.include?("chromium") },
      "chromium" => ->(repository) { repository.start_with?("selenium/") && repository.include?("chromium") }
    }.freeze

    # Maps an image pattern to the provider-neutral ExecutionRunners::ServiceDeclaration
    # type (RDR-054). Matched the same way as ENV_MAPPINGS/RESOURCE_LIMITS: the
    # first pattern the image name includes wins.
    SERVICE_TYPES = {
      "postgres" => :database,
      "redis" => :cache,
      "selenium" => :browser,
      "chromium" => :browser
    }.freeze

    # Network alias naming (paid-svc-a<account_id>-s<id>-<name>) is shared with
    # egress policy snapshots — see Containers::ServiceRuntimeNaming.
    include ServiceRuntimeNaming

    # Provisions all service containers needed by an agent run's project.
    #
    # Records the run→container association before starting containers so
    # that concurrent cleanup decisions (via capacity_inflight_agent_run_count) count
    # this run even if provisioning is still in progress.
    #
    # @param agent_run [AgentRun] The agent run to provision services for
    # @param network [String] Docker network to attach service containers to.
    #   Defaults to NETWORK_NAME (paid_agent). Callers should pass the same
    #   network the agent container will use so services are reachable.
    # @return [Hash] Environment variables hash for the agent container
    # @spec CONTAINER-RUNTIME-004
    def provision(agent_run, network: Containers.agent_network_name, service_names: nil)
      service_containers = selected_service_containers(agent_run.project, service_names)
      return {} if service_containers.empty?

      @network = network
      requested_host = requested_container_host(agent_run)
      Containers::Provision.ensure_network!(network: @network, backend: Containers.backend_for(requested_host))

      # Record association early so concurrent cleanup counts this run.
      container_ids = service_containers.map(&:id)
      agent_run.update!(service_container_ids: container_ids)

      env_vars = {}
      declarations = []

      service_containers.each do |sc|
        begin
          with_backend(resolve_backend(service_container: sc, requested_host: requested_host)) do
            sc.with_lock do
              ensure_running!(sc)
            end

            if sc.image.include?("postgres")
              db_name = per_run_db_name(agent_run)
              create_per_run_database(sc, db_name)
              env = generate_env_vars(sc, db_override: db_name)
            else
              env = generate_env_vars(sc)
            end

            env_vars.merge!(env)
            declarations << service_declaration_for(sc, env: env)
          end
        rescue DatabaseError => e
          log_error("service_provisioner.database_error",
            name: sc.name,
            image: sc.image,
            error: e.message)
          raise
        rescue Error => e
          sc.update!(status: "error", docker_container_id: nil, container_host: nil)
          log_error("service_provisioner.container_error",
            name: sc.name,
            image: sc.image,
            error: e.message)
          raise
        end
      end

      agent_run.update!(service_environment: env_vars)
      agent_run.record_service_declarations!(declarations, container_ids: container_ids)

      env_vars
    end

    # Stops a single service container unconditionally. Intended for cleanup
    # of orphaned containers that have no in-flight capacity runs.
    #
    # @param service_container [ServiceContainer] The container to stop
    def stop_orphaned_container!(service_container)
      with_backend(resolve_backend(service_container: service_container)) do
        stop_container!(service_container)
      end
    end

    # Cleans up service containers that are no longer needed.
    # Only stops containers with no in-flight capacity runs still using them.
    #
    # @param agent_run [AgentRun] The agent run to clean up services for
    # @spec CONTAINER-RUNTIME-004
    def cleanup(agent_run, stale_requeue_count: nil)
      container_ids = agent_run.service_container_ids
      return if container_ids.blank?

      ServiceContainer.where(id: container_ids).find_each do |sc|
        with_backend(resolve_backend(service_container: sc, requested_host: requested_container_host(agent_run))) do
          cleanup_service_container(sc,
            agent_run: agent_run,
            service_environment: agent_run.service_environment,
            stale_requeue_count: stale_requeue_count)
        end
      end

      agent_run.update_columns(service_container_ids: [])
    end

    # Cleans up service containers provisioned outside the normal agent-run
    # lifecycle (e.g. transient preview/screenshot provisioning).
    #
    # Mirrors the per-container work in #cleanup — drops per-run databases for
    # postgres services and stops containers with no remaining in-flight runs —
    # but operates on a caller-supplied container list and environment instead
    # of the agent run's persisted associations, and does not clear those
    # associations. Preview provisioning restores the agent run's persisted
    # service_container_ids/service_environment after provisioning, so its
    # cleanup must not overwrite them (which would clobber the run's real
    # service associations or wipe them to an empty list).
    #
    # A failure on one container is logged and does not abort cleanup of the
    # remaining containers.
    #
    # @param container_ids [Array<Integer>] ServiceContainer IDs to clean up
    # @param agent_run [AgentRun] Agent run the per-run databases belong to
    # @param service_environment [Hash, nil] Environment map carrying
    #   DATABASE_URL used to resolve the per-run database name
    # @param stale_requeue_count [Integer, nil] Override for the per-run DB suffix
    def cleanup_service_containers(container_ids, agent_run:, service_environment:, stale_requeue_count: nil)
      return if container_ids.blank?

      ServiceContainer.where(id: container_ids).find_each do |sc|
        with_backend(resolve_backend(service_container: sc, requested_host: requested_container_host(agent_run))) do
          cleanup_service_container(sc,
            agent_run: agent_run,
            service_environment: service_environment,
            stale_requeue_count: stale_requeue_count)
        end
      rescue => e
        log_warn("service_provisioner.cleanup_container_failed",
          name: sc&.name, error: e.message)
      end
    end

    # Returns the provider-neutral ExecutionRunners::ServiceDeclaration
    # snapshot for the services already provisioned for +agent_run+ (RDR-054).
    # Prefers the point-in-time declaration array persisted by #provision so
    # later RunSpec/manifest generation stays aligned with the live services
    # this run actually attached to; older runs without that snapshot fall
    # back to reconstructing from the persisted ServiceContainer rows.
    #
    # This performs no Docker side effects, so it is safe to call after
    # #provision has already run — RunSpec.from_agent_run calls this once
    # ProvisionServicesActivity has recorded +service_container_ids+, rather
    # than provisioning a second time.
    #
    # @param agent_run [AgentRun]
    # @return [Array<ExecutionRunners::ServiceDeclaration>]
    # @spec CONTAINER-RUNTIME-032
    def service_declarations(agent_run)
      persisted = persisted_service_declarations(agent_run)
      return persisted if persisted

      container_ids = agent_run.service_container_ids
      return [] if container_ids.blank?

      ServiceContainer.where(id: container_ids).map do |sc|
        db_override = sc.image.include?("postgres") ? per_run_db_name(agent_run) : nil
        service_declaration_for(sc, env: generate_env_vars(sc, db_override: db_override))
      end
    end

    private

    def persisted_service_declarations(agent_run)
      snapshot = agent_run.service_declaration_snapshot
      return unless snapshot.present?
      return unless Array(snapshot["container_ids"]).map(&:to_i) == Array(agent_run.service_container_ids).map(&:to_i)

      Array(snapshot["declarations"]).map { |entry| execution_runner_service_declaration(entry) }
    end

    def service_declaration_for(service_container, env:)
      ExecutionRunners::ServiceDeclaration.new(
        name: service_container.name,
        image: service_container.image,
        port: service_container.port,
        env: env,
        type: service_type_for(service_container.image)
      )
    end

    def execution_runner_service_declaration(entry)
      payload = entry.respond_to?(:to_h) ? entry.to_h : {}
      ExecutionRunners::ServiceDeclaration.new(
        name: payload["name"] || payload[:name],
        image: payload["image"] || payload[:image],
        port: payload["port"] || payload[:port],
        env: payload["env"] || payload[:env] || {},
        type: (payload["type"] || payload[:type])&.to_sym
      )
    end

    def service_type_for(image)
      SERVICE_TYPES.each do |pattern, type|
        return type if image.include?(pattern)
      end
      :other
    end

    # NOTE: this class is NOT thread-safe. `with_backend` stashes the resolved
    # backend in @backend and the private `backend` reader relies on that
    # instance variable. If two threads share a ServiceProvisioner instance,
    # one thread's `with_backend` block will corrupt the other thread's view
    # of @backend. Every existing call site already creates a fresh instance
    # per call (`Containers::ServiceProvisioner.new`), which keeps the
    # pattern safe in practice. Do not share instances across threads.

    # @spec EXECUTION-ISOLATION-002
    def selected_service_containers(project, service_names)
      scope = project.service_containers
      names = Array(service_names).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      scope = scope.where(name: names) if names.any?
      scope.to_a
    end

    def requested_container_host(agent_run)
      agent_run.workspace_volume_host
    end

    def resolve_backend(service_container:, requested_host: nil)
      host = if service_container.docker_container_id.present? || service_container.running?
        service_container.container_host.presence || requested_host
      else
        requested_host.presence || service_container.container_host.presence
      end

      Containers.backend_for(host)
    end

    def with_backend(backend)
      previous_backend = @backend
      @backend = backend
      yield
    ensure
      @backend = previous_backend
    end

    # Not thread-safe — see thread-safety note above. Reads the @backend
    # stashed by with_backend, falling back to the process-global default.
    def backend
      @backend || Containers.backend
    end

    def ensure_running!(service_container)
      if service_container.running?
        if docker_container_alive?(service_container.docker_container_id)
          ensure_connected_to_network!(service_container)
          schedule_metrics_collection(service_container)
          return
        else
          log_info("service_provisioner.container_dead", name: service_container.name)
          service_container.update!(status: "stopped", docker_container_id: nil, container_host: nil)
        end
      end

      start_container!(service_container)
    end

    def start_container!(service_container)
      service_container.update!(status: "starting")
      adopted = false

      pull_image(service_container.image)
      docker_container = create_or_replace_container!(service_container)

      # resolve_name_conflict! may adopt an already-running container,
      # updating status to "running" before returning. Skip start if so.
      if service_container.reload.running?
        adopted = true
        ensure_connected_to_network!(service_container)
      else
        backend.start_container(docker_container)
        service_container.update!(
          docker_container_id: docker_container.id,
          container_host: backend.container_host_for(docker_container),
          status: "running"
        )
      end

      wait_for_health!(service_container)
      schedule_metrics_collection(service_container)

      log_info(adopted ? "service_provisioner.adopted" : "service_provisioner.started",
        name: service_container.name,
        image: service_container.image,
        container_id: docker_container.id)
    rescue => e
      # Don't destroy adopted containers — they may be shared by other active runs.
      cleanup_failed_container(docker_container, service_container) unless adopted
      raise Error, "Failed to start service container #{service_container.name}: #{e.message}"
    end

    def stop_container!(service_container)
      if service_container.docker_container_id.present?
        begin
          container = backend.get_container(service_container.docker_container_id)
          begin
            backend.stop_container(container, timeout: 10)
          rescue Docker::Error::NotFoundError, Docker::Error::ClientError
            # Already stopped or gone
          end
          backend.delete_container(container, force: true, v: true)
        rescue Docker::Error::NotFoundError
          # Already gone
        rescue Docker::Error::DockerError => e
          log_warn("service_provisioner.stop_failed",
            name: service_container.name, error: e.message)
        end
      end

      service_container.update!(status: "stopped", docker_container_id: nil, container_host: nil)
      log_info("service_provisioner.stopped", name: service_container.name)
    end

    # Per-container cleanup shared by #cleanup and #cleanup_service_containers.
    # Drops the per-run database (for postgres services) before stopping the
    # container so isolated databases are not left behind, and only stops
    # containers that no other in-flight run still needs.
    def cleanup_service_container(service_container, agent_run:, service_environment:, stale_requeue_count:)
      if service_container.image.include?("postgres")
        db_name = database_name_for(agent_run, service_environment, stale_requeue_count: stale_requeue_count)
        if droppable_per_run_database?(agent_run, service_container, db_name) &&
            no_overlapping_preview_provisions?(agent_run, service_container, db_name)
          drop_per_run_database(service_container, db_name)
        end
      end

      stop_container!(service_container) if service_container.capacity_inflight_agent_run_count.zero?
    end

    def cleanup_failed_container(docker_container, service_container)
      container_id = docker_container&.id || service_container.docker_container_id
      if container_id.present?
        begin
          container = backend.get_container(container_id)
          begin
            backend.stop_container(container, timeout: 10)
          rescue Docker::Error::NotFoundError, Docker::Error::ClientError
            # Already stopped or gone
          end
          backend.delete_container(container, force: true, v: true)
        rescue Docker::Error::NotFoundError
          # Container already gone
        rescue Docker::Error::DockerError => docker_err
          log_warn("service_provisioner.cleanup_failed",
            name: service_container.name,
            container_id: container_id,
            error: docker_err.message)
        end
      end
      # DB status update is handled by the caller outside the with_lock
      # transaction to ensure it is not rolled back.
    end

    def create_or_replace_container!(service_container)
      create_docker_container(service_container)
    rescue Docker::Error::ConflictError, Docker::Error::ServerError => e
      raise unless e.message&.include?("Conflict") && e.message&.include?("already in use")

      log_info("service_provisioner.container_name_conflict", name: service_container.name)
      resolve_name_conflict!(service_container)
    end

    def resolve_name_conflict!(service_container)
      existing = backend.get_container(runtime_name(service_container))
      info = existing.json
      labels = info.dig("Config", "Labels") || {}

      unless labels["paid.service_container"] == "true"
        raise Error, "Container named '#{runtime_name(service_container)}' exists but is not managed by Paid"
      end

      if labels["paid.service_container_id"] != service_container.id.to_s
        raise Error, "Container named '#{runtime_name(service_container)}' belongs to service_container " \
          "#{labels['paid.service_container_id']}, expected #{service_container.id}"
      end

      if info.dig("State", "Running")
        log_info("service_provisioner.adopted_existing",
          name: service_container.name, container_id: existing.id)
        service_container.update!(
          docker_container_id: existing.id,
          container_host: backend.container_host_for(existing),
          status: "running"
        )
        return existing
      end

      remove_stale_container!(existing, runtime_name(service_container))
      create_docker_container(service_container)
    rescue Docker::Error::NotFoundError
      # Container disappeared between conflict detection and lookup; retry create.
      create_docker_container(service_container)
    end

    def remove_stale_container!(existing, name)
      begin
        backend.stop_container(existing, timeout: 10)
      rescue Docker::Error::NotFoundError
        # Already gone
      rescue Docker::Error::DockerError => e
        log_warn("service_provisioner.stale_container_stop_failed",
          name: name, error: e.message)
      end
      backend.delete_container(existing, force: true, v: true)
      log_info("service_provisioner.stale_container_removed", name: name)
    rescue Docker::Error::NotFoundError
      # Container disappeared during cleanup; already removed.
    end

    def create_docker_container(service_container)
      limits = resource_limits_for(service_container.image)
      hardening = hardening_profile_for(service_container)
      env = container_env_for(service_container)
      host = runtime_name(service_container)
      cap_drop = [ "ALL" ]
      cap_add = hardening[:cap_add]
      security_opt = [ "no-new-privileges:true" ]
      user = hardening[:user]

      options = {
        "Image" => service_container.image,
        "name" => host,
        "Env" => env.map { |k, v| "#{k}=#{v}" },
        "ReadonlyRootfs" => hardening[:readonly_rootfs],
        "CapDrop" => cap_drop,
        "CapAdd" => cap_add,
        "SecurityOpt" => security_opt,
        "HostConfig" => {
          "NetworkMode" => @network,
          "Memory" => limits[:memory],
          "MemorySwap" => limits[:memory],
          "CpuPeriod" => 100_000,
          "CpuQuota" => limits[:cpu_quota],
          "PidsLimit" => limits[:pids_limit],
          "CapDrop" => cap_drop,
          "CapAdd" => cap_add,
          "SecurityOpt" => security_opt,
          "Tmpfs" => docker_tmpfs_mounts(hardening[:tmpfs])
        },
        "NetworkingConfig" => {
          "EndpointsConfig" => {
            @network => {
              "Aliases" => [ host ]
            }
          }
        },
        "Labels" => {
          "paid.service_container" => "true",
          "paid.service_container_id" => service_container.id.to_s
        }
      }
      options["User"] = user if user.present?

      healthcheck = healthcheck_for(service_container, env)
      options["Healthcheck"] = healthcheck if healthcheck

      backend.create_container(options)
    end

    def hardening_profile_for(service_container)
      image = service_container.respond_to?(:image) ? service_container.image : service_container
      base = built_in_hardening_profile_for(image)
      overrides = hardening_overrides_for(service_container)

      {
        readonly_rootfs: overrides.fetch(:readonly_rootfs, base.fetch(:readonly_rootfs)),
        user: overrides.key?(:user) ? overrides[:user] : base[:user],
        tmpfs: base.fetch(:tmpfs).merge(overrides.fetch(:tmpfs, {})),
        cap_add: overrides.key?(:cap_add) ? overrides[:cap_add] : base[:cap_add]
      }
    end

    def built_in_hardening_profile_for(image)
      repository = image_repository(image)

      HARDENING_PROFILES.each do |family, profile|
        matcher = HARDENING_PROFILE_MATCHERS.fetch(family)
        return profile if matcher.call(repository)
      end

      DEFAULT_HARDENING_PROFILE
    end

    def hardening_overrides_for(service_container)
      raw = service_container.respond_to?(:env) ? service_container.env[HARDENING_ENV_KEY] : nil
      return {} if raw.blank?
      raise Error, "#{HARDENING_ENV_KEY} must be a JSON object" unless raw.is_a?(Hash)

      override = {}
      if raw.key?("readonly_rootfs")
        readonly_rootfs = raw.fetch("readonly_rootfs")
        unless readonly_rootfs == true || readonly_rootfs == false
          raise Error, "#{HARDENING_ENV_KEY}.readonly_rootfs must be true or false"
        end

        override[:readonly_rootfs] = readonly_rootfs
      end

      override[:user] = raw.fetch("user") if raw.key?("user")

      if raw.key?("cap_add")
        cap_add = raw.fetch("cap_add")
        raise Error, "#{HARDENING_ENV_KEY}.cap_add must be an array" unless cap_add.is_a?(Array)

        normalized_cap_add = cap_add.map { |capability| capability.to_s.upcase }.uniq
        unsupported = normalized_cap_add - SAFE_OVERRIDE_CAPABILITIES
        if unsupported.any?
          raise Error,
            "#{HARDENING_ENV_KEY}.cap_add contains unsupported capabilities: #{unsupported.join(', ')}"
        end

        override[:cap_add] = normalized_cap_add
      end

      override[:tmpfs] = normalize_tmpfs_overrides(raw.fetch("tmpfs")) if raw.key?("tmpfs")
      override
    end

    def normalize_tmpfs_overrides(raw_tmpfs)
      raise Error, "#{HARDENING_ENV_KEY}.tmpfs must be a JSON object" unless raw_tmpfs.is_a?(Hash)

      raw_tmpfs.each_with_object({}) do |(path, options), normalized|
        raise Error, "#{HARDENING_ENV_KEY}.tmpfs entries must be JSON objects" unless options.is_a?(Hash)

        normalized[path.to_s] = {
          size: Integer(options.fetch("size")),
          mode: options.fetch("mode").to_s
        }
        normalized[path.to_s][:uid] = Integer(options.fetch("uid")) if options.key?("uid")
        normalized[path.to_s][:gid] = Integer(options.fetch("gid")) if options.key?("gid")
      end
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "Invalid #{HARDENING_ENV_KEY}.tmpfs override: #{e.message}"
    end

    def docker_tmpfs_mounts(tmpfs)
      tmpfs.transform_values { |options| docker_tmpfs_options(options) }
    end

    def image_repository(image)
      segments = image.to_s.split("@", 2).first.split("/")
      if segments.length > 1 && registry_segment?(segments.first)
        segments = segments.drop(1)
      end

      segments[-1] = segments.last.to_s.split(":", 2).first
      segments.join("/")
    end

    def registry_segment?(segment)
      segment.include?(".") || segment.include?(":") || segment == "localhost"
    end

    def docker_tmpfs_options(options)
      [
        "size=#{options.fetch(:size)}",
        "mode=#{options.fetch(:mode)}",
        ("uid=#{options[:uid]}" if options.key?(:uid)),
        ("gid=#{options[:gid]}" if options.key?(:gid))
      ].compact.join(",")
    end

    def container_env_for(service_container)
      env = service_container.env.except(HARDENING_ENV_KEY)

      return env unless service_container.image.include?("postgres")

      # Normalize Postgres env: treat nil/blank values as missing so they do
      # not override the safe defaults in POSTGRES_DEFAULT_ENV.
      normalized = env.each_with_object({}) do |(key, value), memo|
        next if value.nil?

        stripped = value.to_s.strip
        next if stripped.empty?

        memo[key] = stripped
      end

      POSTGRES_DEFAULT_ENV.merge(normalized)
    end

    def healthcheck_for(service_container, env)
      return nil unless service_container.image.include?("postgres")

      user = env.fetch("POSTGRES_USER", POSTGRES_DEFAULT_ENV["POSTGRES_USER"])
      db = env.fetch("POSTGRES_DB", POSTGRES_DEFAULT_ENV["POSTGRES_DB"])

      {
        "Test" => [ "CMD", "pg_isready", "-U", user, "-d", db ],
        "Interval" => 5_000_000_000,
        "Timeout" => 3_000_000_000,
        "Retries" => 10,
        "StartPeriod" => 5_000_000_000
      }
    end

    def resource_limits_for(image)
      RESOURCE_LIMITS.each do |pattern, limits|
        return limits if image.include?(pattern)
      end
      DEFAULT_RESOURCE_LIMITS
    end

    def pull_image(image)
      backend.pull_image("fromImage" => image)
    rescue Docker::Error::NotFoundError
      raise Error, "Image not found: #{image}"
    rescue Docker::Error::DockerError => e
      raise Error, "Failed to pull image #{image}: #{e.message}"
    end

    def wait_for_health!(service_container)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HEALTH_CHECK_TIMEOUT
      has_healthcheck = nil # nil = unknown, true/false once determined
      docker_container = backend.get_container(service_container.docker_container_id)

      loop do
        # Only query Docker HEALTHCHECK when we haven't confirmed its absence.
        if has_healthcheck != false
          healthcheck = docker_healthcheck_status(service_container)
          # First non-nil response confirms a HEALTHCHECK is configured.
          # A nil response confirms no HEALTHCHECK — skip Docker API on future iterations.
          has_healthcheck = !healthcheck.nil? if has_healthcheck.nil?

          if healthcheck == true
            log_info("service_provisioner.healthy", name: service_container.name)
            return
          end
        end

        # Fall back to TCP probe when no Docker HEALTHCHECK is configured.
        # Service containers (postgres, redis) should always have probe tools,
        # so we pass fallback_on_missing_tools: false to avoid false-healthy.
        if has_healthcheck == false && tcp_port_open?(service_container, docker_container: docker_container)
          log_info("service_provisioner.healthy", name: service_container.name)
          return
        end

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise Error, "Health check timeout for #{service_container.name}:#{service_container.port}"
        end

        sleep HEALTH_CHECK_INTERVAL
      end
    end

    # Checks the Docker-native HEALTHCHECK status when available.
    # Returns true when the container reports "healthy", false when a
    # HEALTHCHECK is configured but the status is anything other than "healthy"
    # (including "unhealthy" or transitional states), and nil when no HEALTHCHECK
    # status is present (so the caller falls back to TCP).
    def docker_healthcheck_status(service_container)
      return nil if service_container.docker_container_id.blank?

      container = backend.get_container(service_container.docker_container_id)
      health_status = container.json.dig("State", "Health", "Status")
      return nil if health_status.nil?

      health_status == "healthy"
    rescue Docker::Error::DockerError, Excon::Error
      nil
    end

    def tcp_port_open?(service_container, docker_container: nil, fallback_on_missing_tools: false)
      docker_container ||= backend.get_container(service_container.docker_container_id)
      Containers::TcpHealthProbe.open?(
        backend: backend,
        container: docker_container,
        host: runtime_name(service_container),
        port: service_container.port,
        fallback_on_missing_tools: fallback_on_missing_tools
      )
    rescue Docker::Error::DockerError, Excon::Error
      false
    end

    def docker_container_alive?(container_id)
      return false if container_id.blank?

      container = backend.get_container(container_id)
      container.info.dig("State", "Running") == true
    rescue Docker::Error::DockerError, Excon::Error
      false
    end

    def ensure_connected_to_network!(service_container)
      container = backend.get_container(service_container.docker_container_id)
      networks = container.info.dig("NetworkSettings", "Networks") || {}
      endpoint = networks.fetch(@network, nil)
      host = runtime_name(service_container)

      if network_alias?(endpoint, host)
        return
      end

      network = backend.get_network(@network)
      network.disconnect(container.id) if endpoint
      network.connect(
        container.id,
        {},
        "EndpointConfig" => { "Aliases" => [ host ] }
      )
      log_info("service_provisioner.network_connected",
        name: service_container.name,
        network: @network,
        container_id: container.id)
    rescue Docker::Error::DockerError, Excon::Error => e
      raise Error, "Failed to attach service container #{service_container.name} to network #{@network}: #{e.message}"
    end

    def network_alias?(endpoint, name)
      Array(endpoint&.fetch("Aliases", nil)).include?(name)
    end

    def generate_env_vars(service_container, db_override: nil)
      host = runtime_name(service_container)

      ENV_MAPPINGS.each do |pattern, generator|
        if service_container.image.include?(pattern)
          return generator.call(service_container, host: host, db_override: db_override)
        end
      end

      # Fallback: generic SERVICE_<NAME>_HOST and SERVICE_<NAME>_PORT
      key = service_container.name.upcase.tr("-", "_")
      {
        "SERVICE_#{key}_HOST" => host,
        "SERVICE_#{key}_PORT" => service_container.port.to_s
      }
    end

    # Generates a unique, safe database name for each agent run attempt.
    # Uses a sanitized ID to ensure valid PostgreSQL identifier.
    def per_run_db_name(agent_run, stale_requeue_count: agent_run.stale_requeue_count)
      "agent_run_#{agent_run.id.to_s.tr('-', '_')}_attempt_#{stale_requeue_count.to_i}"
    end

    # Creates an isolated database for this agent run inside the shared
    # PostgreSQL container. This prevents schema drift caused by cross-branch
    # migration contamination when multiple agent runs share the same database.
    def create_per_run_database(service_container, db_name)
      return unless service_container.docker_container_id.present?

      env = container_env_for(service_container)
      user = env.fetch("POSTGRES_USER", POSTGRES_DEFAULT_ENV["POSTGRES_USER"])
      admin_db = env.fetch("POSTGRES_DB", POSTGRES_DEFAULT_ENV["POSTGRES_DB"])

      container = backend.get_container(service_container.docker_container_id)
      stdout, stderr, status = backend.exec_in_container(container, [
        "psql", "-U", user, "-d", admin_db, "-c",
        "SELECT 1 FROM pg_database WHERE datname = #{postgres_string_literal(db_name)}"
      ])

      if status != 0
        raise DatabaseError, "Failed to check for existing database #{db_name}: #{stderr.join}"
      end

      # Create only if it doesn't already exist (idempotent for retries)
      if stdout.join.exclude?("1 row")
        stdout, stderr, status = backend.exec_in_container(container, [
          "psql", "-U", user, "-d", admin_db, "-c",
          "CREATE DATABASE #{postgres_identifier(db_name)} OWNER #{postgres_identifier(user)}"
        ])

        if status != 0
          raise DatabaseError, "Failed to create per-run database #{db_name}: #{stderr.join}"
        end

        log_info("service_provisioner.database_created",
          db_name: db_name,
          service_container: service_container.name)
      end
    rescue Docker::Error::DockerError, Excon::Error => e
      raise DatabaseError, "Failed to create per-run database #{db_name}: #{e.message}"
    end

    # Drops the per-run database during cleanup. Best-effort: logs
    # failures instead of raising so cleanup can continue.
    def database_name_for(agent_run, service_environment, stale_requeue_count: nil)
      database_url = service_environment&.fetch("DATABASE_URL", nil)
      database_name_from_url(database_url) || per_run_db_name(
        agent_run,
        stale_requeue_count: stale_requeue_count || agent_run.stale_requeue_count
      )
    end

    def database_name_from_url(database_url)
      return if database_url.blank?

      path = URI.parse(database_url).path
      return if path.blank?

      URI.decode_www_form_component(path.delete_prefix("/")).presence
    rescue URI::InvalidURIError
      nil
    end

    def droppable_per_run_database?(agent_run, service_container, db_name)
      return false if db_name.blank?

      if configured_postgres_database_names(service_container).include?(db_name)
        log_info("service_provisioner.database_drop_skipped",
          db_name: db_name,
          service_container: service_container.name,
          reason: "configured_database")
        return false
      end

      return true if per_run_database_name_for?(agent_run, db_name)

      log_info("service_provisioner.database_drop_skipped",
        db_name: db_name,
        service_container: service_container.name,
        reason: "non_matching_database_name")
      false
    end

    def no_overlapping_preview_provisions?(agent_run, service_container, db_name)
      return true unless PreviewProvisionState.where(agent_run_id: agent_run.id).where("active_count > 0").exists?

      log_info("service_provisioner.database_drop_skipped",
        db_name: db_name,
        service_container: service_container.name,
        reason: "preview_overlap_active")
      false
    end

    def configured_postgres_database_names(service_container)
      env = container_env_for(service_container)
      [
        POSTGRES_DEFAULT_ENV["POSTGRES_DB"],
        env["POSTGRES_DB"]
      ].compact.uniq
    end

    def per_run_database_name_for?(agent_run, db_name)
      run_id = Regexp.escape(agent_run.id.to_s.tr("-", "_"))
      db_name.match?(/\Aagent_run_#{run_id}_attempt_\d+\z/)
    end

    def drop_per_run_database(service_container, db_name)
      return unless service_container.docker_container_id.present?
      return unless service_container.running?

      env = container_env_for(service_container)
      user = env.fetch("POSTGRES_USER", POSTGRES_DEFAULT_ENV["POSTGRES_USER"])
      admin_db = env.fetch("POSTGRES_DB", POSTGRES_DEFAULT_ENV["POSTGRES_DB"])

      container = backend.get_container(service_container.docker_container_id)

      # Terminate active connections before dropping
      backend.exec_in_container(container, [
        "psql", "-U", user, "-d", admin_db, "-c",
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = #{postgres_string_literal(db_name)} AND pid <> pg_backend_pid()"
      ])

      _stdout, stderr, status = backend.exec_in_container(container, [
        "psql", "-U", user, "-d", admin_db, "-c",
        "DROP DATABASE IF EXISTS #{postgres_identifier(db_name)}"
      ])

      if status != 0
        log_warn("service_provisioner.database_drop_failed",
          db_name: db_name,
          service_container: service_container.name,
          error: stderr.join)
      else
        log_info("service_provisioner.database_dropped",
          db_name: db_name,
          service_container: service_container.name)
      end
    rescue Docker::Error::DockerError, Excon::Error => e
      log_warn("service_provisioner.database_drop_error",
        db_name: db_name,
        service_container: service_container.name,
        error: e.message)
    end

    def postgres_identifier(value)
      %("#{value.to_s.gsub('"', '""')}")
    end

    def postgres_string_literal(value)
      "'#{value.to_s.gsub("'", "''")}'"
    end

    def schedule_metrics_collection(service_container)
      ServiceContainerMetricsCollectionJob.perform_later(service_container.id)
    rescue GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError
      log_info("service_provisioner.metrics_job_already_enqueued",
        service_container_id: service_container.id)
    end

    def log_info(message, **metadata)
      Rails.logger.info(message: message, **metadata)
    end

    def log_warn(message, **metadata)
      Rails.logger.warn(message: message, **metadata)
    end

    def log_error(message, **metadata)
      Rails.logger.error(message: message, **metadata)
    end
  end
end
