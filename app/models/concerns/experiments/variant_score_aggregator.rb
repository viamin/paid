# frozen_string_literal: true

module Experiments
  # Shared variant score aggregator for variants that track a numeric
  # quality score per assignment (sample_count, total_quality_score,
  # avg_quality_score). The math is identical across AbTestVariant,
  # ConfigurationExperimentVariant, StrategyExperimentVariant, and
  # StyleGuideAbTestVariant; the only difference is the column name
  # (`total_quality_score` / `avg_quality_score` are shared, but the
  # backing table differs).
  #
  # Including models must expose:
  #   * `total_quality_score` (decimal column)
  #   * `sample_count` (integer column)
  #   * `avg_quality_score` (decimal column)
  module VariantScoreAggregator
    module_function

    # Atomically add a brand-new quality score to the variant. Increments the
    # sample_count, accumulates the total, recomputes the avg.
    # The host still needs to `save!` or `update_columns` after this call so
    # each model can decide its write semantics.
    def increment_for_score!(variant, score)
      score_decimal = BigDecimal(score.to_s)
      variant.sample_count += 1
      variant.total_quality_score = BigDecimal("0") if variant.total_quality_score.nil?
      variant.total_quality_score += score_decimal
      variant.avg_quality_score = variant.total_quality_score / variant.sample_count
    end

    # Atomically replace a previously-recorded score. Used when a score is
    # corrected (configuration_experiments / strategy_experiments only).
    def replace_score!(variant, old_score:, new_score:)
      old_decimal = BigDecimal(old_score.to_s)
      new_decimal = BigDecimal(new_score.to_s)
      variant.total_quality_score = (variant.total_quality_score || BigDecimal("0")) - old_decimal + new_decimal
      variant.avg_quality_score = variant.sample_count.positive? ? variant.total_quality_score / variant.sample_count : nil
    end

    # Validate that a quality_score argument is a numeric 0..1 value.
    module ScoreValidations
      module_function

      def valid_score?(score)
        score.is_a?(Numeric) && score >= 0 && score <= 1
      end

      def validate!(score)
        return if valid_score?(score)

        raise ArgumentError, "quality_score must be a number between 0 and 1"
      end
    end
  end
end
