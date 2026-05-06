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

      attr_reader :cluster, :region, :profile

      def initialize(cluster: "default", region: nil, profile: nil, **)
        @cluster = cluster
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
        task_definition = describe_task_definition(service_data.fetch(:taskDefinition))
        container_definitions = updated_container_definitions(service, task_definition[:containerDefinitions], cpu_limit, memory_limit)
        registration = register_task_definition(task_definition, container_definitions)

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
            "--task-definition", task_definition_arn)
        )

        response.fetch(:taskDefinition)
      end

      def updated_container_definitions(service, definitions, cpu_limit, memory_limit)
        target_name = definitions.any? { |definition| definition[:name] == service } ? service : definitions.first&.fetch(:name)
        raise ApiError, "task definition has no container definitions" unless target_name

        definitions.map do |definition|
          next definition unless definition[:name] == target_name

          definition.merge(
            cpu: cpu_limit ? ecs_cpu_units(cpu_limit) : definition[:cpu],
            memory: memory_limit ? ecs_memory_mib(memory_limit) : definition[:memory]
          )
        end
      end

      def register_task_definition(task_definition, container_definitions)
        payload = {
          family: task_definition[:family],
          taskRoleArn: task_definition[:taskRoleArn],
          executionRoleArn: task_definition[:executionRoleArn],
          networkMode: task_definition[:networkMode],
          containerDefinitions: container_definitions,
          volumes: task_definition[:volumes],
          placementConstraints: task_definition[:placementConstraints],
          requiresCompatibilities: task_definition[:requiresCompatibilities],
          cpu: task_definition[:cpu],
          memory: task_definition[:memory],
          runtimePlatform: task_definition[:runtimePlatform],
          pidMode: task_definition[:pidMode],
          ipcMode: task_definition[:ipcMode],
          proxyConfiguration: task_definition[:proxyConfiguration],
          inferenceAccelerators: task_definition[:inferenceAccelerators],
          ephemeralStorage: task_definition[:ephemeralStorage]
        }.compact

        parse_json(
          run_aws("ecs", "register-task-definition",
            "--cli-input-json", JSON.generate(payload))
        )
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

      def ecs_cpu_units(value)
        string = value.to_s.strip
        return (string.delete_suffix("m").to_f / 1000 * 1024).round if string.end_with?("m")

        (string.to_f * 1024).round
      end

      def ecs_memory_mib(value)
        string = value.to_s.strip.downcase
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
        cmd.concat(args)

        stdout, stderr, status = Open3.capture3(*cmd)
        return stdout if status.success?

        raise ApiError, stderr.presence || stdout.presence || "AWS CLI command failed"
      end
    end
  end
end
