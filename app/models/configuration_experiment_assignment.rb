# frozen_string_literal: true

class ConfigurationExperimentAssignment < ApplicationRecord
  belongs_to :configuration_experiment
  belongs_to :configuration_experiment_variant
  belongs_to :agent_run

  validates :agent_run_id, uniqueness: { scope: :configuration_experiment_id }
  validate :configuration_experiment_variant_matches_experiment

  private

  def configuration_experiment_variant_matches_experiment
    return if configuration_experiment_variant.nil? || configuration_experiment.nil?
    return if configuration_experiment_variant.configuration_experiment_id == configuration_experiment_id

    errors.add(:configuration_experiment_variant, "must belong to the same configuration experiment")
  end
end
