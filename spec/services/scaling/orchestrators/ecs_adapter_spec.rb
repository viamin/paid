# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::Orchestrators::EcsAdapter do
  let(:adapter) { described_class.new(cluster: "paid-prod", region: "us-east-1") }
  let(:service_name) { "agent-worker" }

  def expect_service_description(payload)
    allow(adapter).to receive(:run_aws).with(
      "ecs", "describe-services",
      "--cluster", "paid-prod",
      "--services", service_name
    ).and_return(payload.to_json)
  end

  describe "#current_status" do
    let(:ready_service_payload) do
      {
        services: [
          {
            desiredCount: 4,
            runningCount: 4,
            deployments: [
              { status: "PRIMARY", runningCount: 4, rolloutState: "COMPLETED" }
            ]
          }
        ],
        failures: []
      }
    end

    it "returns a ServiceStatus from ECS service data" do
      expect_service_description(ready_service_payload)

      status = adapter.current_status(service: service_name)

      expect(status).to be_a(Scaling::Orchestrators::Data::ServiceStatus)
      expect(status.current_replicas).to eq(4)
      expect(status.desired_replicas).to eq(4)
      expect(status.ready).to be true
    end

    it "raises ApiError when ECS reports a failure" do
      expect_service_description(services: [], failures: [ { arn: "arn", reason: "MISSING" } ])

      expect { adapter.current_status(service: service_name) }
        .to raise_error(described_class::ApiError, /MISSING/)
    end
  end

  describe "#scale" do
    it "updates the ECS desired count" do
      allow(adapter).to receive(:describe_service).with(service_name).and_return({ desiredCount: 2 })
      expect(adapter).to receive(:run_aws).with(
        "ecs", "update-service",
        "--cluster", "paid-prod",
        "--service", service_name,
        "--desired-count", "6"
      ).and_return({ service: { desiredCount: 6 } }.to_json)

      result = adapter.scale(service: service_name, desired_replicas: 6)

      expect(result).to be_a(Scaling::Orchestrators::Data::ScaleResult)
      expect(result.previous_replicas).to eq(2)
      expect(result.desired_replicas).to eq(6)
      expect(result.accepted).to be true
    end
  end

  describe "#set_resource_limits" do
    let(:task_definition) do
      {
        family: service_name,
        taskDefinitionArn: "arn:aws:ecs:task-definition/agent-worker:7",
        networkMode: "awsvpc",
        containerDefinitions: [
          { name: service_name, cpu: 256, memory: 512, essential: true }
        ],
        requiresCompatibilities: [ "FARGATE" ],
        cpu: "512",
        memory: "1024"
      }
    end
    let(:next_task_definition_arn) { "arn:aws:ecs:task-definition/agent-worker:8" }

    def expect_task_definition_registration(expected_cpu: "512", expected_memory: "2048")
      expect(adapter).to receive(:run_aws).with(
        "ecs", "register-task-definition",
        "--cli-input-json", kind_of(String)
      ) do |*args|
        payload = JSON.parse(args.last, symbolize_names: true)
        container = payload.fetch(:containerDefinitions).first
        expect(container[:cpu]).to eq(512)
        expect(container[:memory]).to eq(2048)
        expect(payload[:cpu]).to eq(expected_cpu)
        expect(payload[:memory]).to eq(expected_memory)

        { taskDefinition: { taskDefinitionArn: next_task_definition_arn } }.to_json
      end
    end

    def expect_named_task_definition_registration(named_adapter)
      expect(named_adapter).to receive(:run_aws).with(
        "ecs", "register-task-definition",
        "--cli-input-json", kind_of(String)
      ) do |*args|
        payload = JSON.parse(args.last, symbolize_names: true)

        expect(payload[:containerDefinitions]).to contain_exactly(
          include(name: "web", cpu: 512, memory: 2048),
          include(name: "sidecar", cpu: 128, memory: 256)
        )
        expect(payload[:cpu]).to eq("1024")
        expect(payload[:memory]).to eq("3072")

        { taskDefinition: { taskDefinitionArn: next_task_definition_arn } }.to_json
      end
    end

    def stub_named_adapter_task_definition(named_adapter, task_definition_arn, task_definition)
      allow(named_adapter).to receive(:describe_service)
        .with(service_name)
        .and_return({ taskDefinition: task_definition_arn })
      allow(named_adapter).to receive(:describe_task_definition)
        .with(task_definition_arn)
        .and_return(task_definition)
    end

    def expect_named_adapter_service_update(named_adapter)
      expect(named_adapter).to receive(:run_aws).with(
        "ecs", "update-service",
        "--cluster", "paid-prod",
        "--service", service_name,
        "--task-definition", next_task_definition_arn,
        "--force-new-deployment"
      ).and_return({ service: { taskDefinition: next_task_definition_arn } }.to_json)
    end

    it "registers a new task definition revision and forces a deployment" do
      allow(adapter).to receive(:describe_service)
        .with(service_name)
        .and_return({ taskDefinition: task_definition[:taskDefinitionArn] })
      allow(adapter).to receive(:describe_task_definition)
        .with(task_definition[:taskDefinitionArn])
        .and_return(task_definition)
      expect_task_definition_registration

      expect(adapter).to receive(:run_aws).with(
        "ecs", "update-service",
        "--cluster", "paid-prod",
        "--service", service_name,
        "--task-definition", next_task_definition_arn,
        "--force-new-deployment"
      ).and_return({ service: { taskDefinition: next_task_definition_arn } }.to_json)

      result = adapter.set_resource_limits(service: service_name, cpu_limit: "500m", memory_limit: "2Gi")

      expect(result).to be_a(Scaling::Orchestrators::Data::ResourceUpdateResult)
      expect(result.accepted).to be true
    end

    it "preserves raw ECS CPU-unit inputs when updating container resources" do
      allow(adapter).to receive(:describe_service)
        .with(service_name)
        .and_return({ taskDefinition: task_definition[:taskDefinitionArn] })
      allow(adapter).to receive(:describe_task_definition)
        .with(task_definition[:taskDefinitionArn])
        .and_return(task_definition)
      expect_task_definition_registration(expected_cpu: "512")

      expect(adapter).to receive(:run_aws).with(
        "ecs", "update-service",
        "--cluster", "paid-prod",
        "--service", service_name,
        "--task-definition", next_task_definition_arn,
        "--force-new-deployment"
      ).and_return({ service: { taskDefinition: next_task_definition_arn } }.to_json)

      result = adapter.set_resource_limits(service: service_name, cpu_limit: "512", memory_limit: "2Gi")

      expect(result).to be_a(Scaling::Orchestrators::Data::ResourceUpdateResult)
      expect(result.accepted).to be true
    end

    it "converts fractional vCPU inputs to ECS CPU units" do
      allow(adapter).to receive(:describe_service)
        .with(service_name)
        .and_return({ taskDefinition: task_definition[:taskDefinitionArn] })
      allow(adapter).to receive(:describe_task_definition)
        .with(task_definition[:taskDefinitionArn])
        .and_return(task_definition)
      expect_task_definition_registration(expected_cpu: "512")

      expect(adapter).to receive(:run_aws).with(
        "ecs", "update-service",
        "--cluster", "paid-prod",
        "--service", service_name,
        "--task-definition", next_task_definition_arn,
        "--force-new-deployment"
      ).and_return({ service: { taskDefinition: next_task_definition_arn } }.to_json)

      result = adapter.set_resource_limits(service: service_name, cpu_limit: "0.5", memory_limit: "2Gi")

      expect(result).to be_a(Scaling::Orchestrators::Data::ResourceUpdateResult)
      expect(result.accepted).to be true
    end

    it "short-circuits when the requested limits already match the target container" do
      allow(adapter).to receive(:describe_service)
        .with(service_name)
        .and_return({ taskDefinition: task_definition[:taskDefinitionArn] })
      allow(adapter).to receive(:describe_task_definition)
        .with(task_definition[:taskDefinitionArn])
        .and_return(task_definition)
      expect(adapter).not_to receive(:register_task_definition)
      expect(adapter).not_to receive(:run_aws)

      result = adapter.set_resource_limits(service: service_name, cpu_limit: "250m", memory_limit: "512Mi")

      expect(result).to be_a(Scaling::Orchestrators::Data::ResourceUpdateResult)
      expect(result.accepted).to be true
      expect(result.message).to match(/already match/)
    end

    it "raises when the ECS service name does not match a container definition" do
      mismatched_task_definition = task_definition.merge(
        containerDefinitions: [
          { name: "web", cpu: 256, memory: 512, essential: true },
          { name: "sidekiq", cpu: 256, memory: 512, essential: true }
        ]
      )

      allow(adapter).to receive(:describe_service)
        .with(service_name)
        .and_return({ taskDefinition: task_definition[:taskDefinitionArn] })
      allow(adapter).to receive(:describe_task_definition)
        .with(task_definition[:taskDefinitionArn])
        .and_return(mismatched_task_definition)

      expect do
        adapter.set_resource_limits(service: service_name, cpu_limit: "500m", memory_limit: "2Gi")
      end.to raise_error(described_class::ApiError, /configure container_name/)
    end

    it "updates the configured target container when service and container names differ" do
      named_adapter = described_class.new(cluster: "paid-prod", region: "us-east-1", container_name: "web")
      mismatched_task_definition = task_definition.merge(
        containerDefinitions: [
          { name: "web", cpu: 256, memory: 512, essential: true },
          { name: "sidecar", cpu: 128, memory: 256, essential: false }
        ]
      )

      stub_named_adapter_task_definition(named_adapter, task_definition[:taskDefinitionArn], mismatched_task_definition)
      expect_named_task_definition_registration(named_adapter)
      expect_named_adapter_service_update(named_adapter)

      result = named_adapter.set_resource_limits(service: service_name, cpu_limit: "500m", memory_limit: "2Gi")

      expect(result).to be_a(Scaling::Orchestrators::Data::ResourceUpdateResult)
      expect(result.accepted).to be true
    end
  end

  describe "#healthy?" do
    it "returns true when the AWS CLI can list ECS services" do
      allow(adapter).to receive(:run_aws).with(
        "ecs", "list-services",
        "--cluster", "paid-prod",
        "--max-items", "1"
      ).and_return({ serviceArns: [] }.to_json)

      expect(adapter.healthy?).to be true
    end

    it "returns false when the AWS CLI call fails" do
      allow(adapter).to receive(:run_aws).and_raise(described_class::ApiError, "auth failed")

      expect(adapter.healthy?).to be false
    end
  end
end
