# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ProvisionMcpServersActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }

  describe "#execute" do
    it "provisions MCP servers and returns server specs" do
      provisioner = instance_double(Containers::McpProvisioner)
      allow(Containers::McpProvisioner).to receive(:new).and_return(provisioner)
      allow(Containers::Provision).to receive(:network_for)
        .with(agent_run: agent_run).and_return(NetworkPolicy::NETWORK_NAME)
      allow(provisioner).to receive(:provision)
        .with(agent_run, network: NetworkPolicy::NETWORK_NAME)
        .and_return(
          stdio_servers: [ { "name" => "fs", "transport" => "stdio", "command" => "npx", "args" => [] } ],
          url_servers: [ { "name" => "pg-mcp", "transport" => "sse", "url" => "http://mcp:3000/sse" } ]
        )
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:stdio_servers].size).to eq(1)
      expect(result[:url_servers].size).to eq(1)
    end

    it "returns empty lists when no MCP servers configured" do
      provisioner = instance_double(Containers::McpProvisioner)
      allow(Containers::McpProvisioner).to receive(:new).and_return(provisioner)
      allow(Containers::Provision).to receive(:network_for)
        .with(agent_run: agent_run).and_return(NetworkPolicy::NETWORK_NAME)
      allow(provisioner).to receive(:provision)
        .with(agent_run, network: NetworkPolicy::NETWORK_NAME)
        .and_return(stdio_servers: [], url_servers: [])
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:stdio_servers]).to eq([])
      expect(result[:url_servers]).to eq([])
    end

    it "wraps McpProvisioner::Error as a non-retryable Temporal error" do
      provisioner = instance_double(Containers::McpProvisioner)
      allow(Containers::McpProvisioner).to receive(:new).and_return(provisioner)
      allow(Containers::Provision).to receive(:network_for)
        .with(agent_run: agent_run).and_return(NetworkPolicy::NETWORK_NAME)
      allow(provisioner).to receive(:provision)
        .and_raise(Containers::McpProvisioner::Error, "Image not found: mcp/broken:latest")
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("McpProvisioningFailed")
      }
    end
  end
end
