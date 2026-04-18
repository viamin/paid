# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::Orchestrators::DockerComposeAdapter do
  let(:adapter) { described_class.new(compose_file: "docker-compose.yml", project_name: "test-project") }

  describe "#current_status" do
    it "returns a ServiceStatus from docker compose ps output" do
      ps_output = [
        '{"Name":"test-project-web-1","State":"running"}',
        '{"Name":"test-project-web-2","State":"running"}'
      ].join("\n")

      allow(adapter).to receive(:run_compose).and_return(ps_output)

      status = adapter.current_status(service: "web")

      expect(status).to be_a(Scaling::Orchestrators::Data::ServiceStatus)
      expect(status.service).to eq("web")
      expect(status.current_replicas).to eq(2)
      expect(status.available_replicas).to eq(2)
      expect(status.ready).to be true
    end

    it "reports not ready when containers are not running" do
      ps_output = '{"Name":"test-project-web-1","State":"exited"}'
      allow(adapter).to receive(:run_compose).and_return(ps_output)

      status = adapter.current_status(service: "web")

      expect(status.ready).to be false
      expect(status.available_replicas).to eq(0)
    end

    it "handles empty output for missing services" do
      allow(adapter).to receive(:run_compose).and_return("")

      status = adapter.current_status(service: "missing")

      expect(status.current_replicas).to eq(0)
      expect(status.ready).to be false
    end
  end

  describe "#scale" do
    it "calls docker compose up --scale and returns a ScaleResult" do
      ps_output = '{"Name":"test-project-web-1","State":"running"}'
      allow(adapter).to receive(:run_compose).and_return(ps_output)

      result = adapter.scale(service: "web", desired_replicas: 3)

      expect(result).to be_a(Scaling::Orchestrators::Data::ScaleResult)
      expect(result.previous_replicas).to eq(1)
      expect(result.desired_replicas).to eq(3)
      expect(result.accepted).to be true
    end
  end

  describe "#set_resource_limits" do
    it "updates resource limits on running containers" do
      allow(adapter).to receive_messages(run_compose: "abc123\n", run_command: "")

      result = adapter.set_resource_limits(
        service: "web",
        cpu_limit: "2",
        memory_limit: "1g"
      )

      expect(result).to be_a(Scaling::Orchestrators::Data::ResourceUpdateResult)
      expect(result.accepted).to be true
    end

    it "raises CommandError when no containers are found" do
      allow(adapter).to receive(:run_compose).and_return("")

      expect { adapter.set_resource_limits(service: "web", cpu_limit: "2") }
        .to raise_error(described_class::CommandError, /No running containers/)
    end
  end

  describe "#healthy?" do
    it "returns true when docker compose is available" do
      allow(adapter).to receive(:run_compose).and_return("Docker Compose version v2.0.0\n")

      expect(adapter.healthy?).to be true
    end

    it "returns false when docker compose is not available" do
      allow(adapter).to receive(:run_compose).and_raise(described_class::CommandError, "not found")

      expect(adapter.healthy?).to be false
    end
  end

  describe "includes Scaling::Orchestrator" do
    it "includes the orchestrator interface" do
      expect(described_class.ancestors).to include(Scaling::Orchestrator)
    end
  end
end
