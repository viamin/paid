# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::RoiDashboardStats do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "computes ROI metrics, benchmarks, templates, and summary text" do
      issue = create(:issue, project: project, github_created_at: 4.days.ago)
      run = create(:agent_run, :completed, project: project, issue: issue, created_at: 3.days.ago, completed_at: 2.days.ago,
        cost_cents: 9_000, iterations: 2, goal: "create_pr", pull_request_number: 15)
      create(:quality_metric, :human, agent_run: run, created_at: 1.day.ago, scores: { "pr_merged" => 1.0 })
      create(:roi_benchmark, project: project, merge_rate: 55.0, cost_per_accepted_pr_cents: 12_000)

      stats = described_class.call(project: project)

      expect(stats[:summary]).to include(
        accepted_pr_count: 1,
        created_pr_count: 1,
        merge_rate: 100.0,
        cost_per_accepted_pr_cents: 9_000
      )
      expect(stats[:summary][:average_cycle_time_hours]).to be > 0
      expect(stats[:summary][:rework_rate]).to eq(100.0)
      expect(stats[:benchmarks].first).to include(benchmark_label: "Human-only baseline")
      expect(stats[:trend].size).to eq(6)
      expect(stats[:templates].map { |template| template[:name] }).to include("2-week bug-fix pilot", "Backlog burn-down pilot")
      expect(stats[:executive_summary].join(" ")).to include(project.name)
    end
  end
end
