# frozen_string_literal: true

require "rails_helper"

RSpec.describe PerformanceBenchmarks::Benchmarks::PoolUtilization do
  describe ".call" do
    it "returns skipped when no claimed warm entries exist" do
      result = described_class.call

      expect(result.skipped?).to be(true)
      expect(result.skipped_reason).to include("No claimed warm container entries")
    end

    it "measures warm-container claim latency in milliseconds" do
      project = create(:project)
      agent_run = create(:agent_run, project: project)

      create(:container_pool_entry,
        :claimed,
        project: project,
        agent_run: agent_run,
        warmed_at: 1.day.ago,
        claimed_at: 1.day.ago + 45.seconds)

      result = described_class.call

      expect(result.skipped?).to be(false)
      expect(result.key).to eq("pool_utilization")
      expect(result.samples.first).to be_within(1.0).of(45_000.0)
    end
  end
end
