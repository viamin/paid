# frozen_string_literal: true

module PerformanceBenchmarks
  Measurement = Struct.new(
    :key, :name, :description, :unit, :budget_ms, :regression_threshold,
    :samples, :skipped_reason, :metadata,
    keyword_init: true
  ) do
    def self.skipped(key:, reason:, metadata: {})
      config = Configuration.metric(key)
      new(
        key: key,
        name: config.fetch("name"),
        description: config.fetch("description"),
        unit: "ms",
        budget_ms: config.fetch("budget_ms"),
        regression_threshold: config.fetch("regression_threshold"),
        samples: [],
        skipped_reason: reason,
        metadata: metadata
      )
    end

    def self.from_samples(key:, samples:, metadata: {})
      config = Configuration.metric(key)
      new(
        key: key,
        name: config.fetch("name"),
        description: config.fetch("description"),
        unit: "ms",
        budget_ms: config.fetch("budget_ms"),
        regression_threshold: config.fetch("regression_threshold"),
        samples: samples.map(&:to_f),
        metadata: metadata
      )
    end

    def skipped?
      skipped_reason.present?
    end

    def comparison_value_ms
      p95_ms || avg_ms
    end

    def to_h
      {
        key: key,
        name: name,
        description: description,
        unit: unit,
        budget_ms: budget_ms,
        regression_threshold: regression_threshold,
        sample_count: samples.size,
        min_ms: percentile(0),
        p50_ms: percentile(50),
        p95_ms: p95_ms,
        max_ms: percentile(100),
        avg_ms: avg_ms,
        comparison_value_ms: comparison_value_ms,
        status: status,
        skipped_reason: skipped_reason,
        metadata: metadata
      }.compact
    end

    private

    def status
      return "skipped" if skipped?
      return "pass" if comparison_value_ms <= budget_ms

      "fail"
    end

    def p95_ms
      percentile(95)
    end

    def avg_ms
      return nil if samples.empty?

      (samples.sum / samples.size).round(1)
    end

    def percentile(percent)
      return nil if samples.empty?

      sorted = samples.sort
      index = ((percent / 100.0) * (sorted.size - 1)).ceil
      sorted.fetch(index).round(1)
    end
  end
end
