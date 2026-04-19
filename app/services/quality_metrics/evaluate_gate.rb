# frozen_string_literal: true

module QualityMetrics
  # Evaluates quality gate thresholds against a newly recorded metric.
  # Creates trigger events when a threshold is breached, and recovery
  # events when a previously-breached threshold returns to acceptable range.
  #
  # @example
  #   QualityMetrics::EvaluateGate.call(quality_metric: metric)
  class EvaluateGate
    def self.call(...)
      new(...).call
    end

    def initialize(quality_metric:)
      @quality_metric = quality_metric
      @project = quality_metric.agent_run.project
    end

    def call
      return [] unless @project

      thresholds = @project.quality_gate_thresholds.enabled
      return [] if thresholds.empty?

      events = []
      thresholds.each do |threshold|
        event = evaluate_threshold(threshold)
        events << event if event
      end
      events
    end

    private

    def evaluate_threshold(threshold)
      score = score_for(threshold.metric_key)
      return nil if score.nil?

      previously_breached = last_event_was_trigger?(threshold)

      if threshold.breached?(score) && !previously_breached
        create_event(threshold, score, "trigger")
      elsif !threshold.breached?(score) && previously_breached
        create_event(threshold, score, "recovery")
      end
    end

    def score_for(metric_key)
      if metric_key == "composite_score"
        @quality_metric.composite_score&.to_f
      else
        @quality_metric.scores&.dig(metric_key)&.to_f
      end
    end

    def last_event_was_trigger?(threshold)
      threshold.quality_gate_events
        .where(project: @project)
        .order(created_at: :desc)
        .pick(:event_type) == "trigger"
    end

    def create_event(threshold, score, event_type)
      QualityGateEvent.create!(
        project: @project,
        quality_gate_threshold: threshold,
        quality_metric: @quality_metric,
        event_type: event_type,
        score_value: score,
        threshold_value: threshold.breached_value(score) || threshold.min_threshold || threshold.max_threshold,
        metadata: {
          metric_key: threshold.metric_key,
          severity: threshold.severity
        }
      )
    end
  end
end
