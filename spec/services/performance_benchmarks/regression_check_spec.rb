# frozen_string_literal: true

require "rails_helper"

RSpec.describe PerformanceBenchmarks::RegressionCheck do
  it "passes when current metrics are within budget and baseline threshold" do
    report = report_for(comparison_value_ms: 110)
    baseline = baseline_for(comparison_value_ms: 100)

    result = described_class.new(report: report, baseline: baseline).call

    expect(result).to eq(passed: true, failures: [])
  end

  it "fails when a metric exceeds its budget" do
    report = report_for(comparison_value_ms: 600, budget_ms: 500)
    baseline = baseline_for(comparison_value_ms: 500)

    result = described_class.new(report: report, baseline: baseline).call

    expect(result[:passed]).to be(false)
    expect(result[:failures]).to contain_exactly("Search latency exceeded budget: 600 ms > 500 ms")
  end

  it "fails when a metric exceeds its baseline threshold" do
    report = report_for(comparison_value_ms: 140, budget_ms: 500, regression_threshold: 1.25)
    baseline = baseline_for(comparison_value_ms: 100)

    result = described_class.new(report: report, baseline: baseline).call

    expect(result[:passed]).to be(false)
    expect(result[:failures]).to contain_exactly("Search latency regressed: 140 ms > 125.0 ms baseline threshold")
  end

  it "fails when a required metric is skipped" do
    report = {
      metrics: [
        {
          key: "search_latency",
          name: "Search latency",
          status: "skipped",
          skipped_reason: "No active knowledge artifact exists."
        }
      ]
    }

    result = described_class.new(
      report: report,
      baseline: baseline_for(comparison_value_ms: 100),
      required_metrics: [ "search_latency" ]
    ).call

    expect(result[:passed]).to be(false)
    expect(result[:failures]).to contain_exactly(
      "Search latency is required but skipped: No active knowledge artifact exists."
    )
  end

  it "fails when a required metric is missing" do
    result = described_class.new(
      report: report_for(comparison_value_ms: 100),
      baseline: baseline_for(comparison_value_ms: 100),
      required_metrics: [ "search_latency", "dashboard_load_time" ]
    ).call

    expect(result[:passed]).to be(false)
    expect(result[:failures]).to contain_exactly(
      "dashboard_load_time is required but missing from the benchmark report"
    )
  end

  def report_for(comparison_value_ms:, budget_ms: 500, regression_threshold: 1.25)
    {
      metrics: [
        {
          key: "search_latency",
          name: "Search latency",
          status: "pass",
          comparison_value_ms: comparison_value_ms,
          budget_ms: budget_ms,
          regression_threshold: regression_threshold
        }
      ]
    }
  end

  def baseline_for(comparison_value_ms:)
    {
      metrics: [
        {
          key: "search_latency",
          comparison_value_ms: comparison_value_ms
        }
      ]
    }
  end
end
