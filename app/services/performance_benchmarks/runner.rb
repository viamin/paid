# frozen_string_literal: true

module PerformanceBenchmarks
  class Runner
    BENCHMARKS = [
      Benchmarks::ContainerStartupTime,
      Benchmarks::WorkflowLatency,
      Benchmarks::DashboardLoadTime,
      Benchmarks::SearchLatency
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(benchmarks: BENCHMARKS)
      @benchmarks = benchmarks
    end

    def call
      Report.new(measurements: benchmarks.map(&:call))
    end

    private

    attr_reader :benchmarks
  end
end
