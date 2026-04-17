# frozen_string_literal: true

module Scaling
  module Orchestrators
    # Docker Compose adapter for the scaling orchestrator interface.
    #
    # Provides a development-friendly implementation that translates
    # scaling actions into +docker compose+ CLI commands. Suitable for
    # local development and CI environments where a full orchestrator
    # is not available.
    #
    # == Configuration
    #
    # - +compose_file+ — Path to docker-compose.yml (default: +"docker-compose.yml"+).
    # - +project_name+ — Compose project name (default: derived from directory).
    #
    # == Limitations
    #
    # - Resource limits are applied via +docker update+ on running containers
    #   rather than modifying the Compose file. Changes are not persisted
    #   across restarts.
    # - Scaling uses +docker compose up --scale+ which starts/stops containers.
    class DockerComposeAdapter
      include Scaling::Orchestrator

      class CommandError < OrchestratorError; end

      attr_reader :compose_file, :project_name

      def initialize(compose_file: "docker-compose.yml", project_name: nil, **)
        @compose_file = compose_file
        @project_name = project_name
      end

      def current_status(service:)
        output = run_compose("ps", "--format", "json", service)
        containers = parse_ps_output(output)

        running = containers.count { |c| c[:state] == "running" }

        Data::ServiceStatus.new(
          service: service,
          current_replicas: containers.size,
          desired_replicas: containers.size,
          available_replicas: running,
          cpu_usage: nil,
          memory_usage: nil,
          ready: containers.any? && running == containers.size
        )
      end

      def scale(service:, desired_replicas:)
        current = current_status(service: service)
        previous = current.current_replicas

        run_compose("up", "-d", "--scale", "#{service}=#{desired_replicas}", "--no-recreate", service)

        Data::ScaleResult.new(
          service: service,
          previous_replicas: previous,
          desired_replicas: desired_replicas,
          accepted: true,
          message: "Service #{service} scaled to #{desired_replicas} via docker compose"
        )
      end

      def set_resource_limits(service:, cpu_limit: nil, memory_limit: nil)
        output = run_compose("ps", "-q", service)
        container_ids = output.strip.split("\n").reject(&:blank?)

        raise CommandError, "No running containers found for #{service}" if container_ids.empty?

        container_ids.each do |container_id|
          update_args = [ "docker", "update" ]
          update_args.push("--cpus", cpu_limit) if cpu_limit
          update_args.push("--memory", memory_limit) if memory_limit
          update_args.push(container_id)

          run_command(*update_args)
        end

        Data::ResourceUpdateResult.new(
          service: service,
          cpu_limit: cpu_limit,
          memory_limit: memory_limit,
          accepted: true,
          message: "Resource limits updated for #{container_ids.size} container(s)"
        )
      end

      def healthy?
        run_compose("version")
        true
      rescue StandardError
        false
      end

      private

      def run_compose(*args)
        cmd = compose_base_command + args
        run_command(*cmd)
      end

      def compose_base_command
        cmd = [ "docker", "compose" ]
        cmd.push("-f", compose_file) if compose_file
        cmd.push("-p", project_name) if project_name
        cmd
      end

      def run_command(*cmd)
        stdout, stderr, status = Open3.capture3(*cmd)

        unless status.success?
          raise CommandError, "Command failed (exit #{status.exitstatus}): #{stderr.presence || stdout}"
        end

        stdout
      end

      def parse_ps_output(output)
        return [] if output.blank?

        output.strip.split("\n").filter_map do |line|
          next if line.blank?

          parsed = JSON.parse(line, symbolize_names: true)
          { state: parsed[:State]&.downcase, name: parsed[:Name] }
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
