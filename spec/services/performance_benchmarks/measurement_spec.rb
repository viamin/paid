# frozen_string_literal: true

require "rails_helper"

RSpec.describe PerformanceBenchmarks::Measurement do
  describe ".from_samples" do
    it "summarizes samples with percentile and budget status" do
      measurement = described_class.from_samples(
        key: "search_latency",
        samples: [ 10, 20, 30, 600 ]
      )

      expect(measurement.to_h).to include(
        key: "search_latency",
        sample_count: 4,
        p50_ms: 30.0,
        p95_ms: 600.0,
        avg_ms: 165.0,
        comparison_value_ms: 600.0,
        status: "fail"
      )
    end
  end

  describe ".skipped" do
    it "returns a skipped metric with the configured budget" do
      measurement = described_class.skipped(key: "dashboard_load_time", reason: "No account exists.")

      expect(measurement.to_h).to include(
        key: "dashboard_load_time",
        budget_ms: 1000,
        sample_count: 0,
        status: "skipped",
        skipped_reason: "No account exists."
      )
    end
  end
end
