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
        args.push("--limit-cpu", normalize_cpu_limit(cpu_limit)) if cpu_limit
        args.push("--limit-memory", normalize_memory_limit(memory_limit)) if memory_limit
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
      rescue JSON::ParserError
        false
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

      def normalize_cpu_limit(value)
        string = value.to_s.strip
        raise CommandError, "Invalid docker swarm cpu_limit: #{value.inspect}" if string.blank?

        return format_decimal(string.delete_suffix("m").to_f / 1000) if string.end_with?("m") && numeric?(string.delete_suffix("m"))
        return format_decimal(string.to_f) if numeric?(string)

        raise CommandError, "Invalid docker swarm cpu_limit: #{value.inspect}"
      end

      def normalize_memory_limit(value)
        string = value.to_s.strip
        raise CommandError, "Invalid docker swarm memory_limit: #{value.inspect}" if string.blank?

        match = string.match(/\A(?<amount>\d+(?:\.\d+)?)(?<unit>ki|mi|gi|ti|k|m|g|t)?\z/i)
        raise CommandError, "Invalid docker swarm memory_limit: #{value.inspect}" unless match

        amount = format_decimal(match[:amount].to_f)
        unit = case match[:unit]&.downcase
        when "ki" then "k"
        when "mi" then "m"
        when "gi" then "g"
        when "ti" then "t"
        else
          match[:unit].to_s.downcase
        end

        "#{amount}#{unit}"
      end

      def numeric?(value)
        value.match?(/\A\d+(?:\.\d+)?\z/)
      end

      def format_decimal(value)
        value.to_s.sub(/\.0+\z/, "").sub(/(\.\d*?)0+\z/, '\1')
      end
    end
  end
end
