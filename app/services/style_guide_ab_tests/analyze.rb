# frozen_string_literal: true

module StyleGuideAbTests
  class Analyze
    Result = Struct.new(:status, :winner, :confidence, :improvement, :details, keyword_init: true)

    attr_reader :style_guide_ab_test

    def initialize(style_guide_ab_test:)
      @style_guide_ab_test = style_guide_ab_test
    end

    def self.call(...)
      new(...).analyze
    end

    def analyze
      variants = style_guide_ab_test.style_guide_ab_test_variants.order(:id).to_a
      control = variants.find(&:is_control)

      return Result.new(status: :insufficient_data) unless control
      return Result.new(status: :insufficient_data) unless style_guide_ab_test.sufficient_samples?

      control_scores = scores_for(control)
      return Result.new(status: :insufficient_data) if control_scores.size < 2

      results = variants.reject(&:is_control).filter_map do |variant|
        result_for(control_scores, variant)
      end

      determine_outcome(results)
    end

    private

    def scores_for(variant)
      variant.style_guide_ab_test_assignments
        .where.not(quality_score: nil)
        .pluck(:quality_score)
        .map(&:to_f)
    end

    def result_for(control_scores, variant)
      variant_scores = scores_for(variant)
      return nil if variant_scores.size < 2

      t_result = AbTests::Statistics.welch_t_test(control_scores, variant_scores)
      return nil unless t_result

      {
        variant: variant,
        mean_diff: AbTests::Statistics.mean(variant_scores) - AbTests::Statistics.mean(control_scores),
        p_value: t_result[:p_value],
        significant: t_result[:p_value] < (1 - style_guide_ab_test.confidence_threshold)
      }
    end

    def determine_outcome(results)
      return Result.new(status: :insufficient_data) if results.empty?

      significant_improvements = results.select { |result| result[:significant] && result[:mean_diff] > 0 }

      if significant_improvements.any?
        winner = significant_improvements.max_by { |result| result[:mean_diff] }
        Result.new(
          status: :winner_found,
          winner: winner[:variant],
          confidence: 1 - winner[:p_value],
          improvement: winner[:mean_diff],
          details: results
        )
      elsif results.all? { |result| result[:significant] && result[:mean_diff] < 0 }
        Result.new(status: :control_wins, details: results)
      else
        Result.new(status: :no_significant_difference, details: results)
      end
    end
  end
end
