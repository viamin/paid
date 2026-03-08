# frozen_string_literal: true

module QualityMetrics
  # Calculates a unified composite quality score for an agent run by
  # merging scores from all metric types (automated + human).
  #
  # @example
  #   score = QualityMetrics::CalculateCompositeScore.call(agent_run: agent_run)
  class CalculateCompositeScore
    attr_reader :agent_run

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).calculate
    end

    # Merges scores from all quality metrics and calculates a weighted composite.
    #
    # @return [Float, nil] The composite score (0.0..1.0), or nil if no metrics exist
    def calculate
      metrics = agent_run.quality_metrics.to_a
      return nil if metrics.empty?

      merged_scores = metrics.each_with_object({}) do |metric, combined|
        metric.scores.each { |key, value| combined[key] = value.to_f }
      end

      return nil if merged_scores.empty?

      total_weight = 0.0
      weighted_sum = 0.0

      merged_scores.each do |key, value|
        weight = QualityMetric::SCORE_WEIGHTS[key]
        next unless weight

        total_weight += weight
        weighted_sum += weight * value
      end

      return nil if total_weight.zero?

      (weighted_sum / total_weight).round(4)
    end
  end
end
