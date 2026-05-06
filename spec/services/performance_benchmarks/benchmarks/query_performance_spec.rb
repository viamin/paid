# frozen_string_literal: true

require "rails_helper"

RSpec.describe PerformanceBenchmarks::Benchmarks::QueryPerformance do
  describe ".call" do
    it "returns skipped when no phases exist" do
      result = described_class.call

      expect(result.skipped?).to be(true)
      expect(result.skipped_reason).to include("No completed agent run phases")
    end

    it "measures phase durations" do
      project = create(:project)
      agent_run = create(:agent_run, project: project)

      create(:agent_run_phase,
        agent_run: agent_run,
        phase_key: "provision_container",
        status: "completed",
        started_at: 1.day.ago,
        finished_at: 1.day.ago + 15.seconds,
        duration_seconds: 15)

      result = described_class.call

      expect(result.skipped?).to be(false)
      expect(result.key).to eq("query_performance")
      expect(result.samples).to contain_exactly(15_000.0)
    end
  end
end
