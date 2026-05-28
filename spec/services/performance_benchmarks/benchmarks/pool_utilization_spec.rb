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
      warmed_at = Time.zone.parse("2026-01-01 12:00:00 UTC")
      now = warmed_at + 1.day

      create(:container_pool_entry,
        :claimed,
        project: project,
        agent_run: agent_run,
        warmed_at: warmed_at,
        claimed_at: warmed_at + 45.seconds)

      result = described_class.call(now: now)

      expect(result.skipped?).to be(false)
      expect(result.key).to eq("pool_utilization")
      expect(result.samples.first).to eq(45_000.0)
    end
  end
end
