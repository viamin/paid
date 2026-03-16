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

      QualityMetric.weighted_average(merged_scores)
    end
  end
end
