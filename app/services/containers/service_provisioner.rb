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

    ENV_MAPPINGS = {
      "postgres" => ->(sc) {
        user = sc.env["POSTGRES_USER"] || "agent"
        pass = sc.env["POSTGRES_PASSWORD"] || "agent"
        db = sc.env["POSTGRES_DB"] || "agent_test"
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
        rescue Error
          sc.update!(status: "error", docker_container_id: nil)
          raise
        end
      end

      agent_run.update!(service_environment: env_vars)

      env_vars
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
      Docker::Container.create(
        "Image" => service_container.image,
        "name" => service_container.name,
        "Env" => service_container.env.map { |k, v| "#{k}=#{v}" },
        "HostConfig" => {
          "NetworkMode" => @network
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
      )
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

      loop do
        if tcp_port_open?(service_container.name, service_container.port)
          log_info("service_provisioner.healthy", name: service_container.name)
          return
        end

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise Error, "Health check timeout for #{service_container.name}:#{service_container.port}"
        end

        sleep HEALTH_CHECK_INTERVAL
      end
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
    rescue Docker::Error::DockerError
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

    def log_info(message, **metadata)
      Rails.logger.info(message: message, **metadata)
    end

    def log_warn(message, **metadata)
      Rails.logger.warn(message: message, **metadata)
    end
  end
end
