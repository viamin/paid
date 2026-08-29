# frozen_string_literal: true

require "rails_helper"

# @spec DASHBOARD-CHART-A11Y-006
RSpec.describe "dashboard/_metrics", :no_db, type: :view do
  let(:stats) do
    {
      run_volume: {
        total: 10,
        last_7_days: 3,
        last_30_days: 8,
        active: 1,
        by_status: { "completed" => 6, "failed" => 2, "running" => 1, "queued" => 1 },
        failure_rate: 25.0
      },
      daily_run_status_chart: [
        { name: "Completed", data: { "2026-08-20" => 3, "2026-08-21" => 2 } },
        { name: "Failed", data: { "2026-08-20" => 1, "2026-08-21" => 0 } }
      ],
      daily_outcome_chart: {
        series: [
          { name: "Completed", data: { "2026-08-20" => 3 } },
          { name: "Failed", data: { "2026-08-20" => 1 } }
        ],
        colors: [ "#16a34a", "#dc2626" ],
        completion_rate: { "2026-08-20" => 75.0 },
        overall_total: 4,
        overall_completed: 3,
        overall_completion_rate: 75.0
      },
      cost_and_tokens: {
        total_cost_cents: 500,
        trailing_30d_tokens: 1000,
        trailing_30d_cost_cents: 200,
        avg_cost_per_run_cents: 50,
        avg_tokens_per_run: 100,
        avg_iterations_per_run: 1.5
      },
      duration_percentiles: { p50: 100, p75: 150, p90: 200, avg: 120 },
      duration_trend_chart: {
        series: [
          { name: "Average", data: { "2026-08-20" => 100 } },
          { name: "Median (p50)", data: { "2026-08-20" => 90 } },
          { name: "Trend", data: { "2026-08-20" => 95 } }
        ],
        slope_seconds_per_day: 1.2
      },
      phase_breakdown: {
        "queue" => { avg_seconds: 10, p50_seconds: 8, p75_seconds: 12, p90_seconds: 15 },
        "setup" => { avg_seconds: 5, p50_seconds: 4, p75_seconds: 6, p90_seconds: 8 }
      },
      issue_completion: {
        merged_count: 0,
        runs_per_issue: { avg: 0, min: 0, max: 0, median: 0 },
        time_to_merge: { avg_seconds: 0, p50_seconds: 0, p90_seconds: 0 },
        agent_run_seconds: { avg_seconds: 0, p50_seconds: 0, p90_seconds: 0 }
      },
      cost_by_project: {},
      runner_fallback_stats: { fallback_count: 0, total_runs: 0, fallback_rate: 0.0 },
      runs_by_runner: {},
      runs_by_project: {}
    }
  end

  before do
    allow(view).to receive(:turbo_frame_tag).and_yield
    allow(view).to receive(:dashboard_path).and_return("/dashboard")
  end

  it "renders a captioned accessible table for every chart on the page" do
    render partial: "dashboard/metrics", locals: { stats: stats, account: nil, time_range: "cumulative" }

    tables = Nokogiri::HTML.fragment(rendered).css("table.sr-only")
    captions = tables.map { |table| table.at_css("caption")&.text }

    expect(captions).to contain_exactly(
      "Agent runs per day, stacked by completed and failed status, over the last 30 days.",
      "PR Creation run outcomes per day for Cumulative, grouped by completion status.",
      "Daily PR creation completion rate percentage for Cumulative.",
      "Daily average and median (p50) duration in seconds for completed PR creation runs."
    )
  end
end
