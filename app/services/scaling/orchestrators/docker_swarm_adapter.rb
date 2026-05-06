# frozen_string_literal: true

require "open3"

module Scaling
  module Orchestrators
    # Docker Swarm adapter for the scaling orchestrator interface.
    #
    # Uses the Docker CLI against a Swarm manager to inspect, scale, and
    # update services. This keeps the integration lightweight while matching
    # the development-friendly command-based approach used by
    # {DockerComposeAdapter}.
    class DockerSwarmAdapter
      include Scaling::Orchestrator

      class CommandError < OrchestratorError; end

      def current_status(service:)
        payload = inspect_service(service)
        desired = payload.dig(:Spec, :Mode, :Replicated, :Replicas) || 0
        running = running_task_count(service)

        Data::ServiceStatus.new(
          service: service,
          current_replicas: running,
          desired_replicas: desired,
          available_replicas: running,
          cpu_usage: nil,
          memory_usage: nil,
          ready: desired.positive? && running >= desired
        )
      end

      def scale(service:, desired_replicas:)
        previous = current_status(service: service).desired_replicas
        run_command("docker", "service", "scale", "#{service}=#{desired_replicas}")

        Data::ScaleResult.new(
          service: service,
          previous_replicas: previous,
          desired_replicas: desired_replicas,
          accepted: true,
          message: "Service #{service} scaled to #{desired_replicas} via docker swarm"
        )
      end

      def set_resource_limits(service:, cpu_limit: nil, memory_limit: nil)
        args = [ "docker", "service", "update" ]
        args.push("--limit-cpu", cpu_limit) if cpu_limit
        args.push("--limit-memory", memory_limit) if memory_limit
        args.push(service)
        run_command(*args)

        Data::ResourceUpdateResult.new(
          service: service,
          cpu_limit: cpu_limit,
          memory_limit: memory_limit,
          accepted: true,
          message: "Resource limits updated for #{service}"
        )
      end

      def healthy?
        output = run_command("docker", "info", "--format", "{{json .Swarm}}")
        swarm = JSON.parse(output, symbolize_names: true)

        swarm[:LocalNodeState] == "active" && swarm[:ControlAvailable] == true
      rescue StandardError
        false
      end

      private

      def inspect_service(service)
        output = run_command("docker", "service", "inspect", service, "--format", "{{json .}}")
        JSON.parse(output, symbolize_names: true)
      rescue JSON::ParserError => e
        raise CommandError, "Invalid docker service inspect output: #{e.message}"
      end

      def running_task_count(service)
        output = run_command(
          "docker", "service", "ps", service,
          "--filter", "desired-state=running",
          "--format", "{{json .}}"
        )

        parse_service_tasks(output).count { |task| task[:CurrentState].to_s.start_with?("Running") }
      end

      def parse_service_tasks(output)
        return [] if output.blank?

        output.lines.filter_map do |line|
          next if line.blank?

          JSON.parse(line, symbolize_names: true)
        rescue JSON::ParserError => e
          raise CommandError, "Invalid docker service ps output: #{e.message}"
        end
      end

      def run_command(*cmd)
        stdout, stderr, status = Open3.capture3(*cmd)
        return stdout if status.success?

        raise CommandError, "Command failed (exit #{status.exitstatus}): #{stderr.presence || stdout}"
      end
    end
  end
end
