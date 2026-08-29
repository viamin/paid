# frozen_string_literal: true

require "rails_helper"

# @spec DASHBOARD-CHART-A11Y-006
RSpec.describe "dashboard/_orchestration_decisions", :no_db, type: :view do
  let(:report) do
    {
      summary: {
        total_count: 10,
        successful_count: 6,
        noop_count: 2,
        failed_count: 2,
        project_count: 2,
        actor_count: 3,
        linked_agent_run_count: 5,
        completed_run_count: 4,
        failed_run_count: 1
      },
      daily_volume: [
        { day: "2026-08-20", successful_count: 3, noop_count: 1, failed_count: 0 },
        { day: "2026-08-21", successful_count: 3, noop_count: 1, failed_count: 2 }
      ],
      status_breakdown: [],
      by_decision_type: [],
      outcome_by_decision_type: [],
      by_actor: [],
      by_project: []
    }
  end

  before do
    allow(view).to receive(:turbo_frame_tag).and_yield
  end

  it "renders a captioned accessible table for the decision volume chart" do
    render partial: "dashboard/orchestration_decisions", locals: { report: report, time_range: "cumulative" }

    tables = Nokogiri::HTML.fragment(rendered).css("table.sr-only")
    captions = tables.map { |table| table.at_css("caption")&.text }

    expect(captions).to contain_exactly(
      "Daily orchestration decision counts split by successful, no-op, and failed outcomes."
    )
  end
end
