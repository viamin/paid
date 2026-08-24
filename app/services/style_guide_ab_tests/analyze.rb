# frozen_string_literal: true

module StyleGuideAbTests
  # Analyzes style guide A/B test results using Welch's t-test to determine
  # if any variant is statistically significantly better than control.
  #
  # Thin delegating wrapper around Experiments::Analyze — the shared
  # analyzer handles variant/control math, sufficient-sample checks, and
  # outcome classification once for every experiment framework.
  #
  # @spec STYLE-GUIDE-EVOLUTION-013
  class Analyze
    Result = Experiments::Analyze::Result

    def self.call(style_guide_ab_test:)
      Experiments::Analyze.call(
        experiment: style_guide_ab_test,
        variants_association: :style_guide_ab_test_variants,
        assignments_association: :style_guide_ab_test_assignments,
        score_column: :quality_score
      )
    end
  end
end
