# frozen_string_literal: true

require "rails_helper"

RSpec.describe PerformanceBenchmarks::Report do
  it "serializes JSON-ready report data" do
    generated_at = Time.utc(2026, 4, 21, 12, 0, 0)
    measurement = PerformanceBenchmarks::Measurement.from_samples(
      key: "dashboard_load_time",
      samples: [ 100, 120 ]
    )

    report = described_class.new(measurements: [ measurement ], generated_at: generated_at)

    expect(report.to_h).to include(
      generated_at: "2026-04-21T12:00:00Z",
      summary: { total: 1, passed: 1, failed: 0, skipped: 0 }
    )
    expect(report.to_h.fetch(:metrics).first).to include(
      key: "dashboard_load_time",
      p95_ms: 120.0,
      status: "pass"
    )
  end

  it "renders skipped metric reasons in markdown" do
    measurement = PerformanceBenchmarks::Measurement.skipped(
      key: "container_startup_time",
      reason: "No phase data."
    )

    markdown = described_class.new(measurements: [ measurement ]).to_markdown

    expect(markdown).to include("| Container startup time | 0 | n/a | n/a | 30000 ms | skipped |")
    expect(markdown).to include("- Container startup time: No phase data.")
  end
end
