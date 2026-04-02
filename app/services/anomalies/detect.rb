# frozen_string_literal: true

module Anomalies
  class Detect
    # Default z-score thresholds for anomaly severity.
    WARNING_THRESHOLD = 2.0
    CRITICAL_THRESHOLD = 3.0

    attr_reader :agent_run

    def initialize(agent_run)
      @agent_run = agent_run
    end

    def self.call(agent_run)
      new(agent_run).call
    end

    def call
      Anomalies::UpdateBaseline.call(project, exclude_run: agent_run)

      baselines = project.project_baselines.index_by(&:metric_name)
      return [] if baselines.empty?

      anomalies = []
      ProjectBaseline::METRIC_NAMES.each do |metric_name|
        baseline = baselines[metric_name]
        next unless baseline
        next if baseline.standard_deviation.zero?

        value = metric_value_for(metric_name)
        next if value.nil?

        deviation = (value - baseline.mean) / baseline.standard_deviation
        severity = classify_severity(deviation)
        next unless severity

        anomalies << record_anomaly(metric_name, value, baseline, deviation, severity)
      end

      log_anomalies(anomalies) if anomalies.any?

      anomalies
    end

    private

    def project
      agent_run.project
    end

    def metric_value_for(metric_name)
      case metric_name
      when "tokens_total"
        (agent_run.tokens_input || 0) + (agent_run.tokens_output || 0)
      when "duration_seconds"
        agent_run.duration_seconds
      when "iterations"
        agent_run.iterations
      when "cost_cents"
        agent_run.cost_cents
      end&.to_f
    end

    def classify_severity(deviation)
      abs = deviation.abs
      if abs >= CRITICAL_THRESHOLD
        "critical"
      elsif abs >= WARNING_THRESHOLD
        "warning"
      end
    end

    def anomaly_type(deviation)
      deviation.positive? ? "high_value" : "low_value"
    end

    def record_anomaly(metric_name, value, baseline, deviation, severity)
      AgentRunAnomaly.create!(
        agent_run: agent_run,
        project: project,
        anomaly_type: anomaly_type(deviation),
        severity: severity,
        metric_name: metric_name,
        metric_value: value,
        baseline_mean: baseline.mean,
        baseline_standard_deviation: baseline.standard_deviation,
        deviation_factor: deviation.abs,
        message: build_message(metric_name, value, baseline, deviation, severity)
      )
    end

    def build_message(metric_name, value, baseline, deviation, severity)
      direction = deviation.positive? ? "above" : "below"
      "#{severity.capitalize}: #{metric_name} (#{value.round(1)}) is " \
        "#{deviation.abs.round(1)} standard deviations #{direction} the baseline " \
        "(mean: #{baseline.mean.round(1)}, stddev: #{baseline.standard_deviation.round(1)})"
    end

    def log_anomalies(anomalies)
      anomalies.each do |anomaly|
        Rails.logger.warn(
          message: "anomaly_detection.anomaly_detected",
          project_id: project.id,
          agent_run_id: agent_run.id,
          anomaly_type: anomaly.anomaly_type,
          severity: anomaly.severity,
          metric_name: anomaly.metric_name,
          metric_value: anomaly.metric_value,
          deviation_factor: anomaly.deviation_factor
        )
      end
    end
  end
end
