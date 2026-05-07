# frozen_string_literal: true

module StrategyExperiments
  class Assign
    attr_reader :strategy_experiment, :agent_run

    def initialize(strategy_experiment:, agent_run:)
      @strategy_experiment = strategy_experiment
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).assign
    end

    def assign
      raise ArgumentError, "strategy experiment is not running" unless strategy_experiment.running?

      existing = StrategyExperimentAssignment.find_by(
        strategy_experiment: strategy_experiment,
        agent_run: agent_run
      )
      return existing if existing

      variant = select_variant

      begin
        StrategyExperimentAssignment.create!(
          strategy_experiment: strategy_experiment,
          strategy_experiment_variant: variant,
          agent_run: agent_run
        )
      rescue ActiveRecord::RecordNotUnique
        StrategyExperimentAssignment.find_by!(
          strategy_experiment: strategy_experiment,
          agent_run: agent_run
        )
      end
    end

    private

    def select_variant
      variants = strategy_experiment.strategy_experiment_variants.order(:id).to_a
      raise ArgumentError, "strategy experiment has no variants" if variants.empty?
      return variants.first if variants.size == 1

      assignment_counts = StrategyExperimentAssignment
        .where(strategy_experiment: strategy_experiment, strategy_experiment_variant: variants)
        .group(:strategy_experiment_variant_id)
        .count
      max_count = variants.map { |v| assignment_counts[v.id] || 0 }.max
      weights = variants.map { |v| (max_count - (assignment_counts[v.id] || 0)) + 1 }
      total = weights.sum.to_f

      roll = rand
      cumulative = 0.0

      variants.zip(weights).each do |variant, weight|
        cumulative += weight / total
        return variant if roll < cumulative
      end

      variants.last
    end
  end
end
