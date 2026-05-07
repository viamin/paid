# frozen_string_literal: true

require "open3"

module Scaling
  module Orchestrators
    # Amazon ECS adapter for the scaling orchestrator interface.
    #
    # Integrates with ECS through the AWS CLI so operators can wire the
    # scaling system into existing ECS deployments without adding another SDK
    # dependency to the app.
    class EcsAdapter
      include Scaling::Orchestrator

      class ApiError < OrchestratorError; end

      CPU_LIMIT_PATTERN = /\A\d+(?:\.\d+)?m?\z/.freeze
      MEMORY_LIMIT_PATTERN = /\A\d+(?:\.\d+)?(?:mi|gi|m|g)?\z/i.freeze

      FARGATE_TASK_SIZES = {
        256 => { memory_range: 512..2048, step: 512 },
        512 => { memory_range: 1024..4096, step: 1024 },
        1024 => { memory_range: 2048..8192, step: 1024 },
        2048 => { memory_range: 4096..16384, step: 1024 },
        4096 => { memory_range: 8192..30720, step: 1024 },
        8192 => { memory_range: 16384..61440, step: 4096 },
        16384 => { memory_range: 32768..122880, step: 8192 }
      }.freeze

      attr_reader :cluster, :container_name, :region, :profile

      def initialize(cluster: "default", container_name: nil, region: nil, profile: nil, **)
        @cluster = cluster
        @container_name = container_name
        @region = region
        @profile = profile
      end

      def current_status(service:)
        svc = describe_service(service)
        desired = svc[:desiredCount] || 0
        running = svc[:runningCount] || 0

        Data::ServiceStatus.new(
          service: service,
          current_replicas: running,
          desired_replicas: desired,
          available_replicas: running,
          cpu_usage: nil,
          memory_usage: nil,
          ready: service_ready?(svc)
        )
      end

      def scale(service:, desired_replicas:)
        previous = describe_service(service)[:desiredCount] || 0
        run_aws("ecs", "update-service",
          "--cluster", cluster,
          "--service", service,
          "--desired-count", desired_replicas.to_s)

        Data::ScaleResult.new(
          service: service,
          previous_replicas: previous,
          desired_replicas: desired_replicas,
          accepted: true,
          message: "ECS service #{service} updated to desired count #{desired_replicas}"
        )
      end

      def set_resource_limits(service:, cpu_limit: nil, memory_limit: nil)
        service_data = describe_service(service)
        task_definition_data = describe_task_definition(service_data.fetch(:taskDefinition))
        task_definition = task_definition_data.fetch(:task_definition)
        container_definitions = updated_container_definitions(service, task_definition[:containerDefinitions], cpu_limit, memory_limit)
        return no_op_resource_update(service, cpu_limit, memory_limit) if container_definitions == task_definition[:containerDefinitions]

        registration = register_task_definition(task_definition, container_definitions, task_definition_data[:tags])

        run_aws("ecs", "update-service",
          "--cluster", cluster,
          "--service", service,
          "--task-definition", registration.dig(:taskDefinition, :taskDefinitionArn),
          "--force-new-deployment")

        Data::ResourceUpdateResult.new(
          service: service,
          cpu_limit: cpu_limit,
          memory_limit: memory_limit,
          accepted: true,
          message: "Resource limits updated for ECS service #{service}"
        )
      end

      def healthy?
        run_aws("ecs", "list-services", "--cluster", cluster, "--max-items", "1")
        true
      rescue StandardError
        false
      end

      private

      def describe_service(service)
        response = parse_json(
          run_aws("ecs", "describe-services",
            "--cluster", cluster,
            "--services", service)
        )

        failure = response.fetch(:failures, []).first
        raise ApiError, failure[:reason] || "service #{service} not found" if failure

        response.fetch(:services, []).first || raise(ApiError, "service #{service} not found")
      end

      def describe_task_definition(task_definition_arn)
        response = parse_json(
          run_aws("ecs", "describe-task-definition",
            "--task-definition", task_definition_arn,
            "--include", "TAGS")
        )

        {
          task_definition: response.fetch(:taskDefinition),
          tags: response[:tags]
        }
      end

      def updated_container_definitions(service, definitions, cpu_limit, memory_limit)
        target_name = resolve_target_container_name(service, definitions)

        definitions.map do |definition|
          next definition unless definition[:name] == target_name

          definition.merge(
            cpu: cpu_limit ? ecs_cpu_units(cpu_limit) : definition[:cpu],
            memory: memory_limit ? ecs_memory_mib(memory_limit) : definition[:memory]
          )
        end
      end

      def register_task_definition(task_definition, container_definitions, tags)
        task_resources = updated_task_resources(task_definition, container_definitions)
        payload = {
          family: task_definition[:family],
          taskRoleArn: task_definition[:taskRoleArn],
          executionRoleArn: task_definition[:executionRoleArn],
          networkMode: task_definition[:networkMode],
          containerDefinitions: container_definitions,
          volumes: task_definition[:volumes],
          placementConstraints: task_definition[:placementConstraints],
          requiresCompatibilities: task_definition[:requiresCompatibilities],
          cpu: task_resources[:cpu],
          memory: task_resources[:memory],
          runtimePlatform: task_definition[:runtimePlatform],
          pidMode: task_definition[:pidMode],
          ipcMode: task_definition[:ipcMode],
          proxyConfiguration: task_definition[:proxyConfiguration],
          inferenceAccelerators: task_definition[:inferenceAccelerators],
          ephemeralStorage: task_definition[:ephemeralStorage],
          tags: tags
        }.compact

        parse_json(
          run_aws("ecs", "register-task-definition",
            "--cli-input-json", JSON.generate(payload))
        )
      end

      def no_op_resource_update(service, cpu_limit, memory_limit)
        Data::ResourceUpdateResult.new(
          service: service,
          cpu_limit: cpu_limit,
          memory_limit: memory_limit,
          accepted: true,
          message: "Resource limits already match the requested ECS service configuration"
        )
      end

      def resolve_target_container_name(service, definitions)
        raise ApiError, "task definition has no container definitions" if definitions.blank?

        target_name = container_name || service
        return target_name if definitions.any? { |definition| definition[:name] == target_name }

        raise ApiError,
          "task definition does not contain container #{target_name.inspect}; configure container_name when the ECS service name differs"
      end

      def updated_task_resources(task_definition, container_definitions)
        required_cpu = container_definitions.sum { |definition| definition[:cpu].to_i }
        required_memory = container_definitions.sum { |definition| definition[:memory].to_i }
        current_cpu = task_definition[:cpu].to_i
        current_memory = task_definition[:memory].to_i

        required_cpu = [ required_cpu, current_cpu ].max
        required_memory = [ required_memory, current_memory ].max

        if Array(task_definition[:requiresCompatibilities]).include?("FARGATE")
          fargate_task_resources(required_cpu, required_memory)
        else
          {
            cpu: task_definition[:cpu].present? ? required_cpu.to_s : nil,
            memory: task_definition[:memory].present? ? required_memory.to_s : nil
          }
        end
      end

      def fargate_task_resources(required_cpu, required_memory)
        cpu, config = FARGATE_TASK_SIZES.find do |candidate_cpu, candidate_config|
          next false if candidate_cpu < required_cpu

          memory_range = candidate_config.fetch(:memory_range)
          next false if required_memory > memory_range.end

          aligned_fargate_memory(required_memory, candidate_config).between?(memory_range.begin, memory_range.end)
        end

        raise ApiError, "requested CPU/memory exceeds supported ECS Fargate task sizes" unless cpu && config

        {
          cpu: cpu.to_s,
          memory: aligned_fargate_memory(required_memory, config).to_s
        }
      end

      def aligned_fargate_memory(required_memory, config)
        memory_range = config.fetch(:memory_range)
        step = config.fetch(:step)
        minimum = [ required_memory, memory_range.begin ].max

        aligned = memory_range.begin + (((minimum - memory_range.begin).to_f / step).ceil * step)
        [ aligned, memory_range.end ].min
      end

      def service_ready?(service)
        desired = service[:desiredCount] || 0
        running = service[:runningCount] || 0
        primary = Array(service[:deployments]).find { |deployment| deployment[:status] == "PRIMARY" }

        desired.positive? &&
          running >= desired &&
          primary &&
          primary[:runningCount].to_i >= desired &&
          primary[:rolloutState].to_s.casecmp("COMPLETED").zero?
      end

      # Converts shared-contract cpu_limit values to ECS CPU units.
      # The contract defines "500m" as 500 millicores and "2" as 2 CPUs.
      # ECS uses 1024 units per vCPU, so "2" becomes 2048.
      def ecs_cpu_units(value)
        string = value.to_s.strip
        raise ApiError, "Invalid ECS cpu_limit: #{value.inspect}" if string.blank? || !string.match?(CPU_LIMIT_PATTERN)

        return (string.delete_suffix("m").to_f / 1000 * 1024).round if string.end_with?("m")

        (string.to_f * 1024).round
      end

      def ecs_memory_mib(value)
        string = value.to_s.strip.downcase
        raise ApiError, "Invalid ECS memory_limit: #{value.inspect}" if string.blank? || !string.match?(MEMORY_LIMIT_PATTERN)

        return string.delete_suffix("mi").to_i if string.end_with?("mi")
        return (string.delete_suffix("gi").to_f * 1024).round if string.end_with?("gi")
        return string.delete_suffix("m").to_i if string.end_with?("m")
        return (string.delete_suffix("g").to_f * 1024).round if string.end_with?("g")

        string.to_i
      end

      def parse_json(payload)
        JSON.parse(payload, symbolize_names: true)
      rescue JSON::ParserError => e
        raise ApiError, "Invalid AWS CLI JSON output: #{e.message}"
      end

      def run_aws(*args)
        cmd = [ "aws" ]
        cmd.push("--region", region) if region.present?
        cmd.push("--profile", profile) if profile.present?
        cmd.push("--output", "json")
        cmd.concat(args)

        stdout, stderr, status = Open3.capture3(*cmd)
        return stdout if status.success?

        raise ApiError, stderr.presence || stdout.presence || "AWS CLI command failed"
      end
    end
  end
end
