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
      counts = StrategyExperimentAssignment
        .where(strategy_experiment: strategy_experiment, strategy_experiment_variant: variants)
        .group(:strategy_experiment_variant_id)
        .count
      Experiments::AssignmentPicker.pick(
        variants: variants,
        counts: counts,
        strategy: :inversely_weighted
      )
    end
  end
end
