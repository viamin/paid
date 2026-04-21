# frozen_string_literal: true

module PerformanceBenchmarks
  class RegressionCheck
    attr_reader :report, :baseline

    def initialize(report:, baseline:, required_metrics: [])
      @report = report
      @baseline = baseline
      @required_metrics = required_metrics.map(&:to_s)
    end

    def call
      {
        passed: failures.empty?,
        failures: failures
      }
    end

    private

    attr_reader :required_metrics

    def failures
      @failures ||= missing_required_metric_failures + metric_failures
    end

    def missing_required_metric_failures
      (required_metrics - report_metric_keys).map do |metric|
        "#{metric} is required but missing from the benchmark report"
      end
    end

    def metric_failures
      report_metrics.filter_map do |metric|
        if metric.fetch(:status) == "skipped"
          next required_metric_failure(metric) if required_metrics.include?(metric_key(metric))

          next
        end

        budget_failure(metric) || baseline_failure(metric)
      end
    end

    def report_metrics
      @report_metrics ||= report.fetch(:metrics)
    end

    def report_metric_keys
      @report_metric_keys ||= report_metrics.map { |metric| metric_key(metric) }
    end

    def required_metric_failure(metric)
      reason = metric[:skipped_reason] || metric["skipped_reason"]

      "#{metric_name(metric)} is required but skipped: #{reason}"
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
      @baseline_metrics ||= baseline
        .fetch(:metrics, baseline.fetch("metrics", []))
        .index_by { |metric| metric_key(metric) }
    end

    def metric_key(metric)
      metric[:key] || metric["key"]
    end

    def metric_name(metric)
      metric[:name] || metric["name"] || metric_key(metric)
    end
  end
end
