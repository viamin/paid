# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::Orchestrators::DockerSwarmAdapter do
  let(:adapter) { described_class.new }

  describe "#current_status" do
    it "returns a ServiceStatus from docker service inspect output" do
      inspect_output = {
        Spec: { Mode: { Replicated: { Replicas: 3 } } },
        ServiceStatus: { RunningTasks: 2 }
      }.to_json

      allow(adapter).to receive(:run_command).and_return(inspect_output)

      status = adapter.current_status(service: "agent-worker")

      expect(status).to be_a(Scaling::Orchestrators::Data::ServiceStatus)
      expect(status.current_replicas).to eq(2)
      expect(status.desired_replicas).to eq(3)
      expect(status.ready).to be false
    end
  end

  describe "#scale" do
    it "calls docker service scale and returns a ScaleResult" do
      allow(adapter).to receive(:current_status)
        .with(service: "agent-worker")
        .and_return(double(desired_replicas: 2))
      expect(adapter).to receive(:run_command)
        .with("docker", "service", "scale", "agent-worker=5")
        .and_return("agent-worker scaled")

      result = adapter.scale(service: "agent-worker", desired_replicas: 5)

      expect(result).to be_a(Scaling::Orchestrators::Data::ScaleResult)
      expect(result.previous_replicas).to eq(2)
      expect(result.desired_replicas).to eq(5)
      expect(result.accepted).to be true
    end
  end

  describe "#set_resource_limits" do
    it "updates service limits" do
      expect(adapter).to receive(:run_command)
        .with("docker", "service", "update", "--limit-cpu", "2", "--limit-memory", "1g", "agent-worker")
        .and_return("updated")

      result = adapter.set_resource_limits(service: "agent-worker", cpu_limit: "2", memory_limit: "1g")

      expect(result).to be_a(Scaling::Orchestrators::Data::ResourceUpdateResult)
      expect(result.accepted).to be true
    end
  end

  describe "#healthy?" do
    it "returns true when the node is an active swarm manager" do
      allow(adapter).to receive(:run_command)
        .with("docker", "info", "--format", "{{json .Swarm}}")
        .and_return({ LocalNodeState: "active", ControlAvailable: true }.to_json)

      expect(adapter.healthy?).to be true
    end

    it "returns false when the node is a swarm worker" do
      allow(adapter).to receive(:run_command)
        .with("docker", "info", "--format", "{{json .Swarm}}")
        .and_return({ LocalNodeState: "active", ControlAvailable: false }.to_json)

      expect(adapter.healthy?).to be false
    end

    it "returns false when docker info fails" do
      allow(adapter).to receive(:run_command).and_raise(described_class::CommandError, "unavailable")

      expect(adapter.healthy?).to be false
    end
  end
end
