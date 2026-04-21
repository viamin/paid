# frozen_string_literal: true

require "rails_helper"

RSpec.describe PerformanceBenchmarks::CiSeedData do
  it "creates deterministic data for every CI-required benchmark" do
    described_class.call

    measurements = PerformanceBenchmarks::Runner.call.to_h.fetch(:metrics)

    expect(measurements.pluck(:key, :status)).to contain_exactly(
      [ "container_startup_time", "pass" ],
      [ "workflow_latency", "pass" ],
      [ "dashboard_load_time", "pass" ],
      [ "search_latency", "pass" ]
    )
  end
end
