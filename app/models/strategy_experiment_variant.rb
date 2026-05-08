# frozen_string_literal: true

class StrategyExperimentVariant < ApplicationRecord
  belongs_to :strategy_experiment

  has_many :strategy_experiment_assignments, dependent: :destroy

  validates :strategy_config, presence: true
  validates :sample_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :strategy_experiment_variant_count_within_limit, on: :create

  def parsed_config
    JSON.parse(strategy_config)
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

  def strategy_experiment_variant_count_within_limit
    return if strategy_experiment.nil?

    max_allowed = StrategyExperiment::MAX_VARIANTS + 1
    if strategy_experiment.strategy_experiment_variants.count >= max_allowed
      errors.add(:base, "strategy experiment cannot have more than #{StrategyExperiment::MAX_VARIANTS} variants plus control")
    end
  end
end
