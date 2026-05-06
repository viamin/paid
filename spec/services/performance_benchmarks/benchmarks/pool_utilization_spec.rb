# frozen_string_literal: true

require "rails_helper"

RSpec.describe PerformanceBenchmarks::Benchmarks::PoolUtilization do
  describe ".call" do
    it "returns skipped when no provisions exist" do
      result = described_class.call

      expect(result.skipped?).to be(true)
      expect(result.skipped_reason).to include("No container provisions")
    end

    it "calculates pool hit rate from claimed entries and provisions" do
      project = create(:project)
      agent_run = create(:agent_run, project: project)

      create(:container_pool_entry, :claimed, project: project, agent_run: agent_run, claimed_at: 1.day.ago)
      create(:agent_run_phase,
        agent_run: agent_run,
        phase_key: "provision_container",
        status: "completed",
        started_at: 2.days.ago,
        finished_at: 2.days.ago + 10.seconds,
        duration_seconds: 10)

      result = described_class.call

      expect(result.skipped?).to be(false)
      expect(result.key).to eq("pool_utilization")
      expect(result.samples).not_to be_empty
    end
  end
end
