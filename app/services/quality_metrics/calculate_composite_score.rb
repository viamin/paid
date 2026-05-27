# frozen_string_literal: true

module QualityMetrics
  # Calculates a unified composite quality score for an agent run by
  # merging scores from all metric types (automated + human).
  #
  # @example
  #   score = QualityMetrics::CalculateCompositeScore.call(agent_run: agent_run)
  class CalculateCompositeScore
    # Mirrors QualityMetric::MUTATION_KILL_RATE_WEIGHT, which reserves 10% of
    # create_pr composite scoring for mutation efficacy when that data exists.
    MUTATION_DIMENSION = "mutation_kill_rate"

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
      metrics = QualityMetric.where(agent_run_id: agent_run.id).to_a
      return nil if metrics.empty?

      merged_scores = metrics.each_with_object({}) do |metric, combined|
        metric.scores.each { |key, value| combined[key] = value.to_f unless value.nil? }
        mutation_score = metric.mutation_kill_rate if metric.respond_to?(:mutation_kill_rate)
        combined[MUTATION_DIMENSION] = mutation_score.to_f unless mutation_score.nil?
      end

      weights = QualityMetric.weights_for(goal: agent_run.goal, focus: agent_run.focus)
      QualityMetric.weighted_average(merged_scores, weights: weights)
    end
  end
end
