# frozen_string_literal: true

require "rails_helper"

RSpec.describe PerformanceBenchmarks::Benchmarks::QueryPerformance do
  describe ".call" do
    def create_phase(agent_run, phase_key:, phase_group:, started_at:, duration_seconds:)
      create(:agent_run_phase,
        agent_run: agent_run,
        phase_key: phase_key,
        phase_group: phase_group,
        status: "completed",
        started_at: started_at,
        finished_at: started_at + duration_seconds.seconds,
        duration_seconds: duration_seconds)
    end

    it "returns skipped when no phases exist" do
      result = described_class.call

      expect(result.skipped?).to be(true)
      expect(result.skipped_reason).to include("No completed agent run phases")
    end

    it "measures phase durations" do
      project = create(:project)
      agent_run = create(:agent_run, project: project)

      create_phase(agent_run, phase_key: "provision_execution_environment", phase_group: "setup", started_at: 1.day.ago, duration_seconds: 15)
      create_phase(agent_run, phase_key: "run_agent", phase_group: "agent", started_at: 1.day.ago + 1.minute, duration_seconds: 40)
      create_phase(agent_run, phase_key: "create_pull_request", phase_group: "post", started_at: 1.day.ago + 2.minutes, duration_seconds: 2)
      create_phase(agent_run, phase_key: "push_branch", phase_group: "post", started_at: 1.day.ago + 3.minutes, duration_seconds: 3)

      result = described_class.call

      expect(result.skipped?).to be(false)
      expect(result.key).to eq("query_performance")
      expect(result.samples).to contain_exactly(15_000.0, 40_000.0, 2_000.0)
    end
  end
end
