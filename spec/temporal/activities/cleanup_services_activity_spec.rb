# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CleanupServicesActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }

  describe "#execute" do
    it "cleans up service containers for the agent run" do
      provisioner = instance_double(Containers::ServiceProvisioner)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
      allow(AgentRun).to receive(:find_by).with(id: agent_run.id).and_return(agent_run)
      expect(provisioner).to receive(:cleanup).with(agent_run)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "returns a no-op when agent run does not exist" do
      result = activity.execute(agent_run_id: -1)

      expect(result[:agent_run_id]).to eq(-1)
    end
  end
end
