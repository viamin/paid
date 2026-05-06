# frozen_string_literal: true

module QualityMetrics
  # Provides quality trend analysis with rolling averages by prompt version
  # and project. Supports threshold overlays, gate event markers, and
  # predictive trend lines for quality gate integration.
  #
  # @example Basic trend analysis
  #   trends = QualityMetrics::TrendAnalysis.call(
  #     prompt_version_id: version.id,
  #     window_size: 20
  #   )
  #
  # @example With gate integration
  #   trends = QualityMetrics::TrendAnalysis.call(
  #     project_id: project.id,
  #     include_thresholds: true,
  #     include_gate_events: true,
  #     include_prediction: true
  #   )
  class TrendAnalysis
    attr_reader :scope, :window_size, :project_id

    def initialize(prompt_version_id: nil, project_id: nil, window_size: 20,
      include_thresholds: false, include_gate_events: false,
      include_prediction: false)
      @scope = QualityMetric.with_composite_score
        .joins(:agent_run).where(AgentRun.quality_scoreable_sql)
      @scope = @scope.by_prompt_version(prompt_version_id) if prompt_version_id
      @scope = @scope.by_project(project_id) if project_id
      @window_size = window_size
      @project_id = project_id
      @include_thresholds = include_thresholds
      @include_gate_events = include_gate_events
      @include_prediction = include_prediction
    end

    def self.call(...)
      new(...).analyze
    end

    # @return [Hash] Trend data including rolling average, sample size, and recent scores
    def analyze
      recent_metrics = scope.recent.limit(window_size)
      scores = recent_metrics.pluck(:composite_score)

      result = {
        rolling_average: scores.any? ? (scores.sum / scores.size).round(4) : nil,
        sample_size: scores.size,
        recent_scores: scores,
        min_score: scores.min,
        max_score: scores.max
      }

      result[:thresholds] = thresholds if @include_thresholds
      result[:gate_events] = gate_events if @include_gate_events
      result[:prediction] = prediction(scores) if @include_prediction

      result
    end

    private

    def thresholds
      return [] unless @project_id

      enabled_thresholds.map do |threshold|
        {
          metric_key: threshold.metric_type,
          goal_type: threshold.goal_type,
          min_threshold: threshold.min_value&.to_f,
          max_threshold: nil,
          severity: threshold.enabled? ? "critical" : "info",
          source_scope: threshold.source_scope
        }
      end
    end

    def gate_events
      return [] unless @project_id

      QualityPauseEvent.where(project_id: @project_id)
        .recent.limit(window_size)
        .map do |e|
          {
            event_type: e.event_type == "paused" ? "trigger" : "recovery",
            score_value: e.composite_score&.to_f,
            threshold_value: e.threshold&.to_f,
            metric_key: e.metadata["metric_type"].presence || "composite_score",
            goal_type: e.metadata["goal_type"],
            severity: "critical",
            created_at: e.created_at.iso8601
          }
        end
    end

    # Simple linear regression to predict future scores.
    # Returns projected scores for the next prediction_steps data points.
    #
    # @param scores [Array<BigDecimal>] recent composite scores (newest first)
    # @return [Hash] prediction data with projected values and breach estimate
    def prediction(scores)
      return { projected_scores: [], breach_estimate: nil } if scores.size < 3

      # Reverse so index 0 = oldest
      ordered = scores.reverse.map(&:to_f)
      n = ordered.size

      sum_x = (0...n).sum.to_f
      sum_y = ordered.sum
      sum_xy = (0...n).sum { |i| i * ordered[i] }
      sum_x2 = (0...n).sum { |i| i * i }.to_f

      denominator = n * sum_x2 - sum_x * sum_x
      return { projected_scores: [], breach_estimate: nil } if denominator.zero?

      slope = (n * sum_xy - sum_x * sum_y) / denominator
      intercept = (sum_y - slope * sum_x) / n

      prediction_steps = [ n, 10 ].min
      projected = (n...(n + prediction_steps)).map do |i|
        [ slope * i + intercept, 0.0 ].max.round(4)
      end

      breach_estimate = estimate_breach(slope, intercept, n)

      {
        projected_scores: projected,
        slope: slope.round(6),
        breach_estimate: breach_estimate
      }
    end

    # Estimate how many data points until a threshold might be breached.
    def estimate_breach(slope, intercept, current_n)
      return nil unless @project_id
      return nil if slope >= 0 # Score is stable or improving

      min_thresholds = enabled_thresholds
        .select { |threshold| threshold.metric_type == "composite_score" }
        .filter_map(&:min_value)

      return nil if min_thresholds.empty?

      target = min_thresholds.map(&:to_f).max
      current_projected = slope * current_n + intercept

      return nil if current_projected <= target

      steps = ((target - intercept) / slope).ceil - current_n
      steps.positive? ? steps : nil
    end

    def enabled_thresholds
      @enabled_thresholds ||= QualityThreshold.effective_for(project: Project.find(@project_id))
    end
  end
end
