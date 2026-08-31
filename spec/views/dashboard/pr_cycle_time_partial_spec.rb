# frozen_string_literal: true

require "rails_helper"

# @spec DASHBOARD-CHART-A11Y-006
RSpec.describe "dashboard/_pr_cycle_time", :no_db, type: :view do
  let(:data) do
    {
      merged_counts: { "2026-08-20" => 3 },
      summary: { total_merged: 5, overall_avg_hours: 10.0, overall_p50_hours: 8.0, total_days: 3 },
      series: [
        { name: "Average", data: { "2026-08-20" => 10 } },
        { name: "Median", data: { "2026-08-20" => 8 } }
      ],
      outlier_annotations: {}
    }
  end

  before do
    allow(view).to receive(:turbo_frame_tag).and_yield
    allow(view).to receive(:dashboard_pr_cycle_time_path).and_return("/dashboard/pr_cycle_time")
  end

  it "renders a captioned accessible text for the cycle time chart" do
    render partial: "dashboard/pr_cycle_time", locals: { data: data, time_range: "cumulative", outlier_cutoff: 72 }

    captions = Nokogiri::HTML.fragment(rendered).css("p.sr-only").map { |p| p.text.strip }

    expect(captions).to contain_exactly(
      "Daily average and median hours from issue creation to PR merge, with outliers above 72 hours excluded."
    )
  end
end
