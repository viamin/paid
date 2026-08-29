# frozen_string_literal: true

require "rails_helper"

# @spec DASHBOARD-CHART-A11Y-006
RSpec.describe "runners/_provider_outcomes", :no_db, type: :view do
  let(:provider_outcome_stats) do
    [
      {
        provider: "anthropic",
        total_runs: 10,
        completed: 7,
        completion_rate: 70.0,
        series: [
          { name: "Completed", data: { "2026-08-20" => 7 } },
          { name: "Failed", data: { "2026-08-20" => 3 } }
        ],
        colors: [ "#16a34a", "#dc2626" ]
      }
    ]
  end

  before do
    allow(view).to receive(:runners_path).and_return("/runners")
  end

  it "renders a captioned accessible table for each provider's chart" do
    render partial: "runners/provider_outcomes",
      locals: { provider_outcome_stats: provider_outcome_stats, outcome_time_range: "30d" }

    tables = Nokogiri::HTML.fragment(rendered).css("table.sr-only")
    captions = tables.map { |table| table.at_css("caption")&.text }

    expect(captions).to contain_exactly("Daily run outcomes for anthropic, stacked by status.")
  end
end
