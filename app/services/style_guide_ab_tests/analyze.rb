# frozen_string_literal: true

module StyleGuideAbTests
  class Analyze
    Result = Struct.new(:status, :winner, :confidence, :improvement, keyword_init: true)

    attr_reader :style_guide_ab_test

    def initialize(style_guide_ab_test:)
      @style_guide_ab_test = style_guide_ab_test
    end

    def self.call(...)
      new(...).analyze
    end

    def analyze
      variants = style_guide_ab_test.style_guide_ab_test_variants.includes(:style_guide_ab_test_assignments).order(:id)
      return Result.new(status: :insufficient_data) if variants.size < 2
      return Result.new(status: :insufficient_data) unless style_guide_ab_test.sufficient_samples?

      control = style_guide_ab_test.control_variant
      control_scores = scores_for(control)
      best_variant = nil
      best_result = nil

      variants.where.not(id: control.id).each do |variant|
        variant_scores = scores_for(variant)
        next if control_scores.size < 2 || variant_scores.size < 2

        t_result = AbTests::Statistics.welch_t_test(control_scores, variant_scores)
        next unless t_result

        p_value = t_result[:p_value]
        confidence = 1.0 - p_value
        improvement = AbTests::Statistics.mean(variant_scores) - AbTests::Statistics.mean(control_scores)
        next unless confidence >= style_guide_ab_test.confidence_threshold
        next unless best_result.nil? || improvement > best_result[:improvement]

        best_variant = variant
        best_result = { confidence:, improvement: }
      end

      if best_variant
        Result.new(
          status: :winner_found,
          winner: best_variant,
          confidence: best_result[:confidence],
          improvement: best_result[:improvement]
        )
      else
        Result.new(status: :no_significant_difference)
      end
    end

    private

    def scores_for(variant)
      variant.style_guide_ab_test_assignments.where.not(quality_score: nil).pluck(:quality_score)
    end
  end
end
