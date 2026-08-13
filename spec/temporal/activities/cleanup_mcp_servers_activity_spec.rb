# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CleanupMcpServersActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }

  describe "#execute" do
    it "cleans up MCP sidecar containers" do
      provisioner = instance_double(Containers::McpProvisioner)
      allow(Containers::McpProvisioner).to receive(:new).and_return(provisioner)
      allow(provisioner).to receive(:cleanup).with(agent_run)
      allow(AgentRun).to receive(:find_by).with(id: agent_run.id).and_return(agent_run)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(provisioner).to have_received(:cleanup).with(agent_run)
    end

    it "skips cleanup when agent run is missing" do
      result = activity.execute(agent_run_id: -1)

      expect(result[:agent_run_id]).to eq(-1)
    end
  end
end
