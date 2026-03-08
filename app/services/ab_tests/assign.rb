# frozen_string_literal: true

module AbTests
  # Assigns an agent run to an A/B test variant using weighted random selection.
  # Variants with fewer samples get higher weight to ensure balanced distribution.
  #
  # @example
  #   assignment = AbTests::Assign.call(ab_test: test, agent_run: run)
  #   prompt_version = assignment.ab_test_variant.prompt_version
  class Assign
    attr_reader :ab_test, :agent_run

    def initialize(ab_test:, agent_run:)
      @ab_test = ab_test
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).assign
    end

    def assign
      variant = select_variant
      AbTestAssignment.create!(
        ab_test: ab_test,
        ab_test_variant: variant,
        agent_run: agent_run
      )
    end

    private

    def select_variant
      variants = ab_test.ab_test_variants.to_a
      return variants.first if variants.size == 1

      # Weight inversely by sample count so under-sampled variants catch up.
      max_count = variants.map(&:sample_count).max
      weights = variants.map { |v| (max_count - v.sample_count) + 1 }
      total = weights.sum.to_f

      roll = rand
      cumulative = 0.0

      variants.zip(weights).each do |variant, weight|
        cumulative += weight / total
        return variant if roll < cumulative
      end

      variants.last
    end
  end
end
