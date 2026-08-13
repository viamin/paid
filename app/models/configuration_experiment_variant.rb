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
    raise ArgumentError, "quality score must be a number between 0 and 1" unless valid_score?(score)

    with_lock do
      score_decimal = BigDecimal(score.to_s)

      self.sample_count += 1
      self.total_quality_score = BigDecimal("0") if total_quality_score.nil?
      self.total_quality_score += score_decimal
      self.avg_quality_score = total_quality_score / sample_count
      save!
    end
  end

  private

  def valid_score?(score)
    score.is_a?(Numeric) && score >= 0 && score <= 1
  end

  def configuration_experiment_variant_count_within_limit
    return if configuration_experiment.nil?

    max_allowed = ConfigurationExperiment::MAX_VARIANTS + 1
    if configuration_experiment.configuration_experiment_variants.count >= max_allowed
      errors.add(:base, "configuration experiment cannot have more than #{ConfigurationExperiment::MAX_VARIANTS} variants plus control")
    end
  end
end
