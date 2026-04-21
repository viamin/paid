# frozen_string_literal: true

module PerformanceBenchmarks
  class RegressionCheck
    attr_reader :report, :baseline

    def initialize(report:, baseline:)
      @report = report
      @baseline = baseline
    end

    def call
      {
        passed: failures.empty?,
        failures: failures
      }
    end

    private

    def failures
      @failures ||= report.fetch(:metrics).filter_map do |metric|
        next if metric.fetch(:status) == "skipped"

        budget_failure(metric) || baseline_failure(metric)
      end
    end

    def budget_failure(metric)
      value = metric[:comparison_value_ms] || metric["comparison_value_ms"]
      budget = metric[:budget_ms] || metric["budget_ms"]
      return nil if value.nil? || budget.nil? || value.to_f <= budget.to_f

      "#{metric_name(metric)} exceeded budget: #{value} ms > #{budget} ms"
    end

    def baseline_failure(metric)
      baseline_metric = baseline_metrics[metric_key(metric)]
      return nil if baseline_metric.nil?

      current = metric[:comparison_value_ms] || metric["comparison_value_ms"]
      previous = baseline_metric[:comparison_value_ms] || baseline_metric["comparison_value_ms"]
      threshold = metric[:regression_threshold] || metric["regression_threshold"]
      return nil if current.nil? || previous.nil? || previous.to_f.zero?

      limit = previous.to_f * threshold.to_f
      return nil if current.to_f <= limit

      "#{metric_name(metric)} regressed: #{current} ms > #{limit.round(1)} ms baseline threshold"
    end

    def baseline_metrics
      @baseline_metrics ||= baseline.fetch(:metrics, baseline.fetch("metrics", [])).index_by { |metric| metric_key(metric) }
    end

    def metric_key(metric)
      metric[:key] || metric["key"]
    end

    def metric_name(metric)
      metric[:name] || metric["name"] || metric_key(metric)
    end
  end
end
