# frozen_string_literal: true

module AbTests
  # Promotes the winning variant's prompt version as the new default
  # for the associated prompt.
  #
  # @example
  #   AbTests::PromoteWinner.call(ab_test: completed_test)
  class PromoteWinner
    attr_reader :ab_test

    def initialize(ab_test:)
      @ab_test = ab_test
    end

    def self.call(...)
      new(...).promote
    end

    def promote
      validate!

      prompt = ab_test.prompt
      winning_version = ab_test.winner_variant.prompt_version

      prompt.update!(current_version: winning_version)
      winning_version
    end

    private

    def validate!
      raise ArgumentError, "A/B test is not completed" unless ab_test.completed?
      raise ArgumentError, "A/B test has no winner" unless ab_test.winner_variant
    end
  end
end
