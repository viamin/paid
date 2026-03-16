# frozen_string_literal: true

module AbTests
  # Analyzes A/B test results using Welch's t-test to determine
  # if any variant is statistically significantly better than control.
  #
  # @example
  #   result = AbTests::Analyze.call(ab_test: test)
  #   result[:status]     # => :winner_found, :control_wins, :no_significant_difference, :insufficient_data
  #   result[:winner]     # => AbTestVariant (if winner_found)
  #   result[:confidence] # => 0.97 (if winner_found)
  class Analyze
    Result = Struct.new(:status, :winner, :confidence, :improvement, :details, keyword_init: true)

    attr_reader :ab_test

    def initialize(ab_test:)
      @ab_test = ab_test
    end

    def self.call(...)
      new(...).analyze
    end

    def analyze
      variants = ab_test.ab_test_variants.order(:id).to_a
      control = variants.find(&:is_control)

      return Result.new(status: :insufficient_data) unless control
      return Result.new(status: :insufficient_data) unless all_have_minimum_samples?(variants)

      control_scores = scores_for(control)
      return Result.new(status: :insufficient_data) if control_scores.size < 2

      results = variants.reject(&:is_control).map do |variant|
        variant_scores = scores_for(variant)
        next nil if variant_scores.size < 2

        t_result = Statistics.welch_t_test(control_scores, variant_scores)
        {
          variant: variant,
          mean_diff: Statistics.mean(variant_scores) - Statistics.mean(control_scores),
          p_value: t_result[:p_value],
          significant: t_result[:p_value] < (1 - ab_test.confidence_threshold)
        }
      end.compact

      determine_outcome(results)
    end

    private

    def all_have_minimum_samples?(variants)
      variants.all? { |v| v.sample_count >= ab_test.min_samples_per_variant }
    end

    def scores_for(variant)
      variant.ab_test_assignments
             .where.not(quality_score: nil)
             .pluck(:quality_score)
             .map(&:to_f)
    end

    def determine_outcome(results)
      return Result.new(status: :insufficient_data) if results.empty?

      significant_improvements = results.select { |r| r[:significant] && r[:mean_diff] > 0 }

      if significant_improvements.any?
        winner = significant_improvements.max_by { |r| r[:mean_diff] }
        Result.new(
          status: :winner_found,
          winner: winner[:variant],
          confidence: 1 - winner[:p_value],
          improvement: winner[:mean_diff],
          details: results
        )
      elsif results.all? { |r| r[:significant] && r[:mean_diff] < 0 }
        Result.new(status: :control_wins, details: results)
      else
        Result.new(status: :no_significant_difference, details: results)
      end
    end
  end
end
