# frozen_string_literal: true

require "docker-api"
require "socket"

module Containers
  # Manages Docker lifecycle for service containers (PostgreSQL, Redis, etc.)
  # that agents need for running tests and setup commands.
  #
  # Service containers are attached to the same Docker network as the agent
  # container (paid_agent for API-key mode, paid_internal for subscription-auth)
  # so they are always reachable from the agent.
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

    POSTGRES_DEFAULT_ENV = {
      "POSTGRES_USER" => "agent",
      "POSTGRES_PASSWORD" => "agent",
      "POSTGRES_DB" => "agent_test"
    }.freeze

    ENV_MAPPINGS = {
      "postgres" => ->(sc) {
        defaults = POSTGRES_DEFAULT_ENV
        user = sc.env["POSTGRES_USER"].to_s.strip.presence || defaults["POSTGRES_USER"]
        pass = sc.env["POSTGRES_PASSWORD"].to_s.strip.presence || defaults["POSTGRES_PASSWORD"]
        db = sc.env["POSTGRES_DB"].to_s.strip.presence || defaults["POSTGRES_DB"]
        { "DATABASE_URL" => "postgres://#{user}:#{pass}@#{sc.name}:#{sc.port}/#{db}" }
      },
      "redis" => ->(sc) {
        { "REDIS_URL" => "redis://#{sc.name}:#{sc.port}" }
      },
      "selenium" => ->(sc) {
        { "SELENIUM_URL" => "http://#{sc.name}:#{sc.port}" }
      },
      "chromium" => ->(sc) {
        { "SELENIUM_URL" => "http://#{sc.name}:#{sc.port}" }
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

    # Provisions all service containers needed by an agent run's project.
    #
    # Records the run→container association before starting containers so
    # that concurrent cleanup decisions (via active_agent_run_count) count
    # this run even if provisioning is still in progress.
    #
    # @param agent_run [AgentRun] The agent run to provision services for
    # @param network [String] Docker network to attach service containers to.
    #   Defaults to NETWORK_NAME (paid_agent). Callers should pass the same
    #   network the agent container will use so services are reachable.
    # @return [Hash] Environment variables hash for the agent container
    def provision(agent_run, network: NetworkPolicy::NETWORK_NAME)
      service_containers = agent_run.project.service_containers.to_a
      return {} if service_containers.empty?

      @network = network
      NetworkPolicy.ensure_network!

      # Record association early so concurrent cleanup counts this run.
      container_ids = service_containers.map(&:id)
      agent_run.update!(service_container_ids: container_ids)

      env_vars = {}

      service_containers.each do |sc|
        begin
          sc.with_lock do
            ensure_running!(sc)
            env_vars.merge!(generate_env_vars(sc))
          end
        rescue Error => e
          sc.update!(status: "error", docker_container_id: nil)
          log_error("service_provisioner.container_error",
            name: sc.name,
            image: sc.image,
            error: e.message)
          raise
        end
      end

      agent_run.update!(service_environment: env_vars)

      env_vars
    end

    # Stops a single service container unconditionally. Intended for cleanup
    # of orphaned containers that have no active agent runs.
    #
    # @param service_container [ServiceContainer] The container to stop
    def stop_orphaned_container!(service_container)
      stop_container!(service_container)
    end

    # Cleans up service containers that are no longer needed.
    # Only stops containers with no active agent runs still using them.
    #
    # @param agent_run [AgentRun] The agent run to clean up services for
    def cleanup(agent_run)
      container_ids = agent_run.service_container_ids
      return if container_ids.blank?

      ServiceContainer.where(id: container_ids).find_each do |sc|
        if sc.active_agent_run_count == 0
          stop_container!(sc)
        end
      end

      agent_run.update!(service_container_ids: [])
    end

    private

    def ensure_running!(service_container)
      if service_container.running?
        if docker_container_alive?(service_container.docker_container_id)
          schedule_metrics_collection(service_container)
          return
        else
          log_info("service_provisioner.container_dead", name: service_container.name)
          service_container.update!(status: "stopped", docker_container_id: nil)
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
      else
        docker_container.start
        service_container.update!(docker_container_id: docker_container.id, status: "running")
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
          container = Docker::Container.get(service_container.docker_container_id)
          container.stop(timeout: 10)
          container.delete(force: true)
        rescue Docker::Error::NotFoundError
          # Already gone
        rescue Docker::Error::DockerError => e
          log_warn("service_provisioner.stop_failed",
            name: service_container.name, error: e.message)
        end
      end

      service_container.update!(status: "stopped", docker_container_id: nil)
      log_info("service_provisioner.stopped", name: service_container.name)
    end

    def cleanup_failed_container(docker_container, service_container)
      container_id = docker_container&.id || service_container.docker_container_id
      if container_id.present?
        begin
          container = Docker::Container.get(container_id)
          container.stop(timeout: 10)
          container.delete(force: true)
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
      existing = Docker::Container.get(service_container.name)
      info = existing.json
      labels = info.dig("Config", "Labels") || {}

      unless labels["paid.service_container"] == "true"
        raise Error, "Container named '#{service_container.name}' exists but is not managed by Paid"
      end

      if labels["paid.service_container_id"] != service_container.id.to_s
        raise Error, "Container named '#{service_container.name}' belongs to service_container " \
          "#{labels['paid.service_container_id']}, expected #{service_container.id}"
      end

      if info.dig("State", "Running")
        log_info("service_provisioner.adopted_existing",
          name: service_container.name, container_id: existing.id)
        service_container.update!(docker_container_id: existing.id, status: "running")
        return existing
      end

      remove_stale_container!(existing, service_container.name)
      create_docker_container(service_container)
    rescue Docker::Error::NotFoundError
      # Container disappeared between conflict detection and lookup; retry create.
      create_docker_container(service_container)
    end

    def remove_stale_container!(existing, name)
      begin
        existing.stop(timeout: 10)
      rescue Docker::Error::NotFoundError
        # Already gone
      rescue Docker::Error::DockerError => e
        log_warn("service_provisioner.stale_container_stop_failed",
          name: name, error: e.message)
      end
      existing.delete(force: true)
      log_info("service_provisioner.stale_container_removed", name: name)
    rescue Docker::Error::NotFoundError
      # Container disappeared during cleanup; already removed.
    end

    def create_docker_container(service_container)
      limits = resource_limits_for(service_container.image)
      env = container_env_for(service_container)

      options = {
        "Image" => service_container.image,
        "name" => service_container.name,
        "Env" => env.map { |k, v| "#{k}=#{v}" },
        "HostConfig" => {
          "NetworkMode" => @network,
          "Memory" => limits[:memory],
          "MemorySwap" => limits[:memory],
          "CpuPeriod" => 100_000,
          "CpuQuota" => limits[:cpu_quota],
          "PidsLimit" => limits[:pids_limit]
        },
        "NetworkingConfig" => {
          "EndpointsConfig" => {
            @network => {
              "Aliases" => [ service_container.name ]
            }
          }
        },
        "Labels" => {
          "paid.service_container" => "true",
          "paid.service_container_id" => service_container.id.to_s
        }
      }

      healthcheck = healthcheck_for(service_container, env)
      options["Healthcheck"] = healthcheck if healthcheck

      Docker::Container.create(options)
    end

    def container_env_for(service_container)
      env = service_container.env

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
        "Test" => [ "CMD", "pg_isready", "-h", "127.0.0.1", "-p", service_container.port.to_s, "-U", user, "-d", db ],
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
      Docker::Image.create("fromImage" => image)
    rescue Docker::Error::NotFoundError
      raise Error, "Image not found: #{image}"
    rescue Docker::Error::DockerError => e
      raise Error, "Failed to pull image #{image}: #{e.message}"
    end

    def wait_for_health!(service_container)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HEALTH_CHECK_TIMEOUT
      has_healthcheck = nil # nil = unknown, true/false once determined

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
        if has_healthcheck == false && tcp_port_open?(service_container.name, service_container.port)
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

      container = Docker::Container.get(service_container.docker_container_id)
      health_status = container.json.dig("State", "Health", "Status")
      return nil if health_status.nil?

      health_status == "healthy"
    rescue Docker::Error::DockerError, Excon::Error
      nil
    end

    def tcp_port_open?(host, port)
      socket = Socket.tcp(host, port, connect_timeout: HEALTH_CHECK_INTERVAL)
      socket.close
      true
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError
      false
    end

    def docker_container_alive?(container_id)
      return false if container_id.blank?

      container = Docker::Container.get(container_id)
      container.info.dig("State", "Running") == true
    rescue Docker::Error::DockerError, Excon::Error
      false
    end

    def generate_env_vars(service_container)
      ENV_MAPPINGS.each do |pattern, generator|
        if service_container.image.include?(pattern)
          return generator.call(service_container)
        end
      end

      # Fallback: generic SERVICE_<NAME>_HOST and SERVICE_<NAME>_PORT
      key = service_container.name.upcase.tr("-", "_")
      {
        "SERVICE_#{key}_HOST" => service_container.name,
        "SERVICE_#{key}_PORT" => service_container.port.to_s
      }
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
