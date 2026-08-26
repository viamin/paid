# frozen_string_literal: true

require "rails_helper"

RSpec.describe PageLoadPerformance::CommentSection do
  def comparison(status:, route: "dashboard", baseline: 640, current: 1_100, trailing: nil)
    PageLoadPerformance::Comparison.new(
      route_name: route,
      status: status,
      metric: "lcp_ms",
      baseline_ms: baseline,
      current_ms: current,
      delta_ms: current && baseline ? current - baseline : nil,
      trailing_median_ms: trailing,
      finding: nil
    )
  end

  # @spec PAGE-LOAD-REGRESSION-007
  it "renders a per-route table of baseline, current and delta" do
    body = described_class.call(comparisons: [ comparison(status: "regressed") ])

    expect(body).to include("dashboard")
    expect(body).to include("640")
    expect(body).to include("1100")
    expect(body).to include("+460")
  end

  # @spec PAGE-LOAD-REGRESSION-007
  it "distinguishes regressed, unchanged, not comparable and no-baseline routes" do
    body = described_class.call(comparisons: [
      comparison(status: "regressed", route: "dashboard"),
      comparison(status: "unchanged", route: "settings", current: 650),
      comparison(status: "not_comparable", route: "billing"),
      comparison(status: "no_baseline", route: "reports", baseline: nil, current: 700)
    ])

    expect(body).to match(/reports.*no baseline/i)
    expect(body).to match(/billing.*not comparable/i)
    expect(body).not_to match(/reports.*regress/i)
  end

  # @spec PAGE-LOAD-REGRESSION-007
  it "shows the trailing median from the ledger as trend context" do
    body = described_class.call(comparisons: [ comparison(status: "regressed", trailing: 700) ])

    expect(body).to include("700")
  end

  # @spec PAGE-LOAD-REGRESSION-007
  it "escapes route names so a crafted route cannot break the table" do
    body = described_class.call(comparisons: [ comparison(status: "regressed", route: "dash|board`x") ])

    expect(body).to include("dash\\|board\\`x")
    expect(body.lines.count { |line| line.start_with?("|") }).to eq(3)
  end

  # @spec PAGE-LOAD-FOLLOWUP-006
  it "says when automated attempts are exhausted" do
    finding = instance_double(PageLoadRegressionFinding, followup_exhausted?: true)
    exhausted = PageLoadPerformance::Comparison.new(
      route_name: "dashboard", status: "regressed", metric: "lcp_ms",
      baseline_ms: 640, current_ms: 1_100, delta_ms: 460, trailing_median_ms: nil, finding: finding
    )

    expect(described_class.call(comparisons: [ exhausted ])).to include("attempts exhausted")
  end

  # @spec PAGE-LOAD-MEASURE-008
  it "renders nothing when there are no comparisons" do
    expect(described_class.call(comparisons: [])).to be_nil
  end
end
