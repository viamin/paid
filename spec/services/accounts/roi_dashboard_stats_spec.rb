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
  end
end
