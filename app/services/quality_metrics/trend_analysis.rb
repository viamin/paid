# frozen_string_literal: true

module QualityMetrics
  # Provides quality trend analysis with rolling averages by prompt version
  # and project. Used by A/B testing framework and prompt evolution.
  #
  # @example
  #   trends = QualityMetrics::TrendAnalysis.call(
  #     prompt_version_id: version.id,
  #     window_size: 20
  #   )
  class TrendAnalysis
    attr_reader :scope, :window_size

    def initialize(prompt_version_id: nil, project_id: nil, window_size: 20)
      @scope = QualityMetric.with_composite_score
      @scope = @scope.by_prompt_version(prompt_version_id) if prompt_version_id
      @scope = @scope.by_project(project_id) if project_id
      @window_size = window_size
    end

    def self.call(...)
      new(...).analyze
    end

    # @return [Hash] Trend data including rolling average, sample size, and recent scores
    def analyze
      scores = scope.recent.limit(window_size).pluck(:composite_score)

      {
        rolling_average: scores.any? ? (scores.sum / scores.size).round(4) : nil,
        sample_size: scores.size,
        recent_scores: scores,
        min_score: scores.min,
        max_score: scores.max
      }
    end
  end
end
