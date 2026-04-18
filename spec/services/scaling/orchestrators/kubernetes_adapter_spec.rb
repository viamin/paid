# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::Orchestrators::KubernetesAdapter do
  let(:adapter) { described_class.new(namespace: "test", api_url: "https://k8s.example.com", bearer_token: "test-token") }

  let(:deployment_response) do
    {
      "metadata" => { "name" => "agent-worker" },
      "spec" => { "replicas" => 3 },
      "status" => {
        "replicas" => 3,
        "availableReplicas" => 3,
        "readyReplicas" => 3
      }
    }
  end

  let(:stubs) { Faraday::Adapter::Test::Stubs.new }

  let(:test_connection) do
    Faraday.new(url: "https://k8s.example.com") do |f|
      f.request :json
      f.response :json
      f.adapter :test, stubs
    end
  end

  before do
    allow(adapter).to receive(:connection).and_return(test_connection)
  end

  describe "#current_status" do
    it "returns a ServiceStatus with deployment information" do
      stubs.get("/apis/apps/v1/namespaces/test/deployments/agent-worker") do
        [ 200, { "Content-Type" => "application/json" }, deployment_response.to_json ]
      end

      status = adapter.current_status(service: "agent-worker")

      expect(status).to be_a(Scaling::Orchestrators::Data::ServiceStatus)
      expect(status.service).to eq("agent-worker")
      expect(status.current_replicas).to eq(3)
      expect(status.desired_replicas).to eq(3)
      expect(status.available_replicas).to eq(3)
      expect(status.ready).to be true
    end

    it "raises ApiError when the deployment is not found" do
      stubs.get("/apis/apps/v1/namespaces/test/deployments/missing") do
        [ 404, { "Content-Type" => "application/json" }, { "message" => "not found" }.to_json ]
      end

      expect { adapter.current_status(service: "missing") }
        .to raise_error(described_class::ApiError)
    end
  end

  describe "#scale" do
    it "patches the deployment and returns a ScaleResult" do
      stubs.get("/apis/apps/v1/namespaces/test/deployments/agent-worker") do
        [ 200, { "Content-Type" => "application/json" }, deployment_response.to_json ]
      end
      stubs.patch("/apis/apps/v1/namespaces/test/deployments/agent-worker") do
        [ 200, { "Content-Type" => "application/json" }, deployment_response.to_json ]
      end

      result = adapter.scale(service: "agent-worker", desired_replicas: 5)

      expect(result).to be_a(Scaling::Orchestrators::Data::ScaleResult)
      expect(result.previous_replicas).to eq(3)
      expect(result.desired_replicas).to eq(5)
      expect(result.accepted).to be true
    end

    it "raises ApiError when the patch request fails" do
      stubs.get("/apis/apps/v1/namespaces/test/deployments/agent-worker") do
        [ 200, { "Content-Type" => "application/json" }, deployment_response.to_json ]
      end
      stubs.patch("/apis/apps/v1/namespaces/test/deployments/agent-worker") do
        [ 422, { "Content-Type" => "application/json" }, { "message" => "invalid" }.to_json ]
      end

      expect { adapter.scale(service: "agent-worker", desired_replicas: 5) }
        .to raise_error(described_class::ApiError, /422/)
    end
  end

  describe "#set_resource_limits" do
    it "patches the deployment and returns a ResourceUpdateResult" do
      stubs.patch("/apis/apps/v1/namespaces/test/deployments/agent-worker") do
        [ 200, { "Content-Type" => "application/json" }, deployment_response.to_json ]
      end

      result = adapter.set_resource_limits(
        service: "agent-worker",
        cpu_limit: "500m",
        memory_limit: "512Mi"
      )

      expect(result).to be_a(Scaling::Orchestrators::Data::ResourceUpdateResult)
      expect(result.cpu_limit).to eq("500m")
      expect(result.memory_limit).to eq("512Mi")
      expect(result.accepted).to be true
    end
  end

  describe "#healthy?" do
    it "returns true when the API responds successfully" do
      stubs.get("/api/v1/namespaces/test") do
        [ 200, { "Content-Type" => "application/json" }, { "status" => "ok" }.to_json ]
      end

      expect(adapter.healthy?).to be true
    end

    it "returns false when the API returns an error status" do
      stubs.get("/api/v1/namespaces/test") do
        [ 403, { "Content-Type" => "application/json" }, { "message" => "forbidden" }.to_json ]
      end

      expect(adapter.healthy?).to be false
    end

    it "returns false when the API is unreachable" do
      stubs.get("/api/v1/namespaces/test") do
        raise Faraday::ConnectionFailed, "refused"
      end

      expect(adapter.healthy?).to be false
    end
  end

  describe "includes Scaling::Orchestrator" do
    it "includes the orchestrator interface" do
      expect(described_class.ancestors).to include(Scaling::Orchestrator)
    end
  end
end
