# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CleanupContainerActivity do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:activity) { described_class.new }

  describe "#execute" do
    it "calls cleanup_container on the agent run" do
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      expect(agent_run).to receive(:cleanup_container)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
