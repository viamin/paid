# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::PoolWarmer do
  let(:project) { create(:project) }

  before do
    allow(Containers::PoolManager).to receive_messages(enabled?: true, target_size: 2)
  end

  describe ".call" do
    it "returns hold when pool is disabled" do
      allow(Containers::PoolManager).to receive(:enabled?).and_return(false)

      result = described_class.call(project: project)

      expect(result[:action]).to eq(:hold)
      expect(result[:boost]).to eq(0)
    end

    it "returns hold when queued runs are below threshold" do
      create(:agent_run, project: project, status: "queued")

      result = described_class.call(project: project)

      expect(result[:action]).to eq(:hold)
    end

    it "boosts pool target when demand is high" do
      create_list(:agent_run, 3, project: project, status: "queued")
      manager = instance_double(Containers::PoolManager, replenish: nil)
      allow(Containers::PoolManager).to receive(:new).and_return(manager)

      result = described_class.call(project: project)

      expect(result[:action]).to eq(:boosted)
      expect(result[:boost]).to be > 0
      expect(result[:boosted_target]).to be > 2
      expect(manager).to have_received(:replenish)
    end

    it "caps boost at MAX_PREDICTIVE_BOOST" do
      create_list(:agent_run, 20, project: project, status: "queued")
      manager = instance_double(Containers::PoolManager, replenish: nil)
      allow(Containers::PoolManager).to receive(:new).and_return(manager)

      result = described_class.call(project: project)

      expect(result[:boost]).to be <= described_class::MAX_PREDICTIVE_BOOST
    end

    it "does not count non-queued runs" do
      create_list(:agent_run, 3, project: project, status: "running")
      create(:agent_run, project: project, status: "queued")

      result = described_class.call(project: project)

      expect(result[:action]).to eq(:hold)
    end
  end
end
