# frozen_string_literal: true

module StyleGuideAbTests
  class PromoteWinner
    attr_reader :style_guide_ab_test

    def initialize(style_guide_ab_test:)
      @style_guide_ab_test = style_guide_ab_test
    end

    def self.call(...)
      new(...).promote
    end

    def promote
      raise ArgumentError, "A/B test is not completed" unless style_guide_ab_test.completed?
      raise ArgumentError, "A/B test has no winner" unless style_guide_ab_test.winner_variant

      style_guide = style_guide_ab_test.style_guide
      winning_version = style_guide_ab_test.winner_variant.style_guide_version

      style_guide.with_lock do
        style_guide.update!(current_version: winning_version)
      end

      winning_version
    end
  end
end
