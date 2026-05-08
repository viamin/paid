# frozen_string_literal: true

class StrategyExperimentAssignment < ApplicationRecord
  belongs_to :strategy_experiment
  belongs_to :strategy_experiment_variant
  belongs_to :agent_run

  validates :agent_run_id, uniqueness: { scope: :strategy_experiment_id }
  validate :strategy_experiment_variant_matches_experiment

  private

  def strategy_experiment_variant_matches_experiment
    return if strategy_experiment_variant.nil? || strategy_experiment.nil?
    return if strategy_experiment_variant.strategy_experiment_id == strategy_experiment_id

    errors.add(:strategy_experiment_variant, "must belong to the same strategy experiment")
  end
end
