# frozen_string_literal: true

class ConfigurationExperimentVariant < ApplicationRecord
  belongs_to :configuration_experiment

  has_many :configuration_experiment_assignments, dependent: :destroy

  validates :config_value, presence: true
  validates :sample_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :configuration_experiment_variant_count_within_limit, on: :create

  def parsed_value
    JSON.parse(config_value)
  end

  def record_quality_score!(score)
    Experiments::VariantScoreAggregator::ScoreValidations.validate!(score)

    with_lock do
      Experiments::VariantScoreAggregator.increment_for_score!(self, score)
      save!
    end
  end

  private

  def configuration_experiment_variant_count_within_limit
    return if configuration_experiment.nil?

    max_allowed = ConfigurationExperiment::MAX_VARIANTS + 1
    if configuration_experiment.configuration_experiment_variants.count >= max_allowed
      errors.add(:base, "configuration experiment cannot have more than #{ConfigurationExperiment::MAX_VARIANTS} variants plus control")
    end
  end
end
