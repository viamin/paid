# frozen_string_literal: true

require "rails_helper"

# @spec DASHBOARD-FILTER-A11Y-002
RSpec.describe "dashboard/_performance", :no_db, type: :view do
  let(:stats) do
    {
      performance_by_outcome: {
        "completed" => {
          run_count: 5,
          avg_cost_cents: 100,
          avg_tokens: 200,
          avg_duration_seconds: 60,
          total_cost_cents: 500,
          total_tokens: 1000
        }
      },
      performance_by_goal: {
        "create_pr" => {
          run_count: 5,
          avg_cost_cents: 100,
          avg_tokens: 200,
          avg_duration_seconds: 60,
          by_outcome: {
            "completed" => { run_count: 5, avg_cost_cents: 100, avg_duration_seconds: 60 }
          }
        }
      }
    }
  end

  before do
    allow(view).to receive(:turbo_frame_tag).and_yield
    allow(view).to receive(:dashboard_performance_path).and_return("/dashboard/performance")
  end

  it "marks the active status filter link with aria-current=page" do
    render partial: "dashboard/performance",
      locals: { stats: stats, time_range: "cumulative", status_filter: "failed", goal_filter: "all" }

    labels = DashboardHelper::STATUS_FILTER_LABELS.values
    links = Nokogiri::HTML.fragment(rendered).css("a").select { |link| labels.include?(link.text) }
    current_links = links.select { |link| link["aria-current"] == "page" }

    expect(current_links.map(&:text)).to eq([ "Failed" ])
  end

  it "marks the active goal filter link with aria-current=page" do
    render partial: "dashboard/performance",
      locals: { stats: stats, time_range: "cumulative", status_filter: "all", goal_filter: "create_pr" }

    labels = DashboardHelper::GOAL_FILTER_LABELS.values
    links = Nokogiri::HTML.fragment(rendered).css("a").select { |link| labels.include?(link.text) }
    current_links = links.select { |link| link["aria-current"] == "page" }

    expect(current_links.map(&:text)).to eq([ "PR Coding" ])
  end
end
