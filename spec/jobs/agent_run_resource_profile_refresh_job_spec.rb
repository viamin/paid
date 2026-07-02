# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunResourceProfileRefreshJob, :no_db do
  describe "#perform" do
    let(:agent_run) { instance_double(AgentRun) }
    let(:system_access_depth) { [ 0 ] }
    let(:refresh_call_depth) { [ nil ] }

    before do
      allow(AgentRun).to receive(:find_by).with(id: 123).and_return(agent_run)
      allow(AgentRunResourceProfiles::RefreshForRun).to receive(:call) do
        refresh_call_depth[0] = system_access_depth.fetch(0)
      end
      allow(TenantContext).to receive(:with_system_access) do |&block|
        system_access_depth[0] += 1
        block.call
      ensure
        system_access_depth[0] -= 1
      end
    end

    it "refreshes profiles within system access" do
      described_class.perform_now(123)

      expect(AgentRunResourceProfiles::RefreshForRun).to have_received(:call).with(agent_run: agent_run)
      expect(refresh_call_depth.fetch(0)).to eq(2)
    end

    it "skips refresh when the run no longer exists" do
      allow(AgentRun).to receive(:find_by).with(id: 123).and_return(nil)

      described_class.perform_now(123)

      expect(AgentRunResourceProfiles::RefreshForRun).not_to have_received(:call)
    end
  end
end
