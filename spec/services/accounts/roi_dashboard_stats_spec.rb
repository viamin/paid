# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::RoiDashboardStats do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "rolls up benchmark averages using only rows with metric values" do
      create(:roi_benchmark,
        project: project,
        benchmark_type: "human_only",
        name: "Human-only baseline",
        accepted_pr_count: 2,
        merge_rate: 50.0)
      create(:roi_benchmark,
        project: project,
        benchmark_type: "human_only",
        name: "Human-only baseline",
        accepted_pr_count: 8,
        merge_rate: nil)

      stats = described_class.call(account: account)

      expect(stats[:benchmark_rollups].first).to include(
        benchmark_label: "Human-only baseline",
        accepted_pr_count: 10,
        merge_rate: 50.0
      )
    end

    it "returns nil rollup metrics when all benchmark rows have zero accepted PRs" do
      create(:roi_benchmark,
        project: project,
        accepted_pr_count: 0,
        merge_rate: 40.0,
        average_cycle_time_hours: 24.0,
        rework_rate: 15.0,
        defect_escape_rate: 5.0,
        cost_per_accepted_pr_cents: 12_000)

      stats = described_class.call(account: account)

      expect(stats[:benchmark_rollups].first).to include(
        accepted_pr_count: 0,
        merge_rate: nil,
        average_cycle_time_hours: nil,
        rework_rate: nil,
        defect_escape_rate: nil,
        cost_per_accepted_pr_cents: nil
      )
    end

    it "builds per-project summaries from a single preloaded run set" do
      other_project = create(:project, account: account, name: "Beta")

      create_accepted_run(project:, issue_created_at: 5.days.ago, run_created_at: 4.days.ago, merged_at: 2.days.ago, cost_cents: 6_000,
        pull_request_number: 11)
      create_accepted_run(project: other_project, issue_created_at: 4.days.ago, run_created_at: 3.days.ago, merged_at: 1.day.ago,
        cost_cents: 4_000, pull_request_number: 12)

      stats = described_class.call(account: account)

      expect(stats[:project_rows].map { |row| [ row[:project].name, row[:summary][:cost_per_accepted_pr_cents] ] }).to eq([
        [ "Beta", 4_000 ],
        [ project.name, 6_000 ]
      ])
    end

    it "excludes preview provisioning runs from ROI summaries" do
      create_accepted_run(project:, issue_created_at: 5.days.ago, run_created_at: 4.days.ago, merged_at: 2.days.ago, cost_cents: 6_000,
        pull_request_number: 11)
      create_preview_run(project:, issue_created_at: 4.days.ago, run_created_at: 3.days.ago, merged_at: 1.day.ago, cost_cents: 20_000,
        pull_request_number: 12)

      stats = described_class.call(account: account)

      expect(stats[:summary][:created_pr_count]).to eq(1)
      expect(stats[:summary][:accepted_pr_count]).to eq(1)
      expect(stats[:summary][:total_cost_cents]).to eq(6_000)
      expect(stats[:project_rows].find { |row| row[:project] == project }.dig(:summary, :cost_per_accepted_pr_cents)).to eq(6_000)
    end
  end

  def create_accepted_run(project:, issue_created_at:, run_created_at:, merged_at:, cost_cents:, pull_request_number:)
    issue = create(:issue, project:, github_created_at: issue_created_at)
    run = create(:agent_run, :completed,
      project:,
      issue:,
      created_at: run_created_at,
      completed_at: run_created_at + 1.day,
      cost_cents:,
      goal: "create_pr",
      pull_request_number:)
    create(:quality_metric, :human, agent_run: run, created_at: merged_at, scores: { "pr_merged" => 1.0 })
  end

  def create_preview_run(project:, issue_created_at:, run_created_at:, merged_at:, cost_cents:, pull_request_number:)
    issue = create(:issue, project:, github_created_at: issue_created_at)
    run = create(:agent_run, :completed, :internal_agent,
      project:,
      issue:,
      created_at: run_created_at,
      completed_at: run_created_at + 1.day,
      cost_cents:,
      goal: "create_pr",
      pull_request_number:,
      synthetic: true,
      external_metadata: { "preview_session" => true })
    create(:quality_metric, :human, agent_run: run, created_at: merged_at, scores: { "pr_merged" => 1.0 })
  end
end
