# frozen_string_literal: true

module AbTests
  # Analyzes A/B test results using Welch's t-test to determine
  # if any variant is statistically significantly better than control.
  #
  # Thin delegating wrapper around Experiments::Analyze — the shared
  # analyzer handles variant/control math, sufficient-sample checks, and
  # outcome classification once for every experiment framework.
  #
  # @example
  #   result = AbTests::Analyze.call(ab_test: test)
  #   result[:status]     # => :winner_found, :control_wins, :no_significant_difference, :insufficient_data
  #   result[:winner]     # => AbTestVariant (if winner_found)
  #   result[:confidence] # => 0.97 (if winner_found)
  class Analyze
    Result = Experiments::Analyze::Result

    def self.call(ab_test:)
      Experiments::Analyze.call(
        experiment: ab_test,
        variants_association: :ab_test_variants,
        assignments_association: :ab_test_assignments,
        score_column: :quality_score
      )
    end
  end
end
