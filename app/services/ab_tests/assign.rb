# frozen_string_literal: true

module AbTests
  # Assigns an agent run to an A/B test variant using weighted random selection.
  # Variants with fewer samples get higher weight to ensure balanced distribution.
  #
  # Integration: call from AgentExecutionWorkflow where prompt_version is resolved,
  # passing the running A/B test for the prompt. Use the returned assignment's
  # variant prompt_version instead of the default. See also AbTests::RecordResult.
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
      raise ArgumentError, "A/B test is not running" unless ab_test.running?

      existing = AbTestAssignment.find_by(ab_test: ab_test, agent_run: agent_run)
      return existing if existing

      variant = select_variant

      begin
        AbTestAssignment.create!(
          ab_test: ab_test,
          ab_test_variant: variant,
          agent_run: agent_run
        )
      rescue ActiveRecord::RecordNotUnique
        AbTestAssignment.find_by!(ab_test: ab_test, agent_run: agent_run)
      end
    end

    private

    def select_variant
      variants = ab_test.ab_test_variants.to_a
      return variants.first if variants.size == 1

      # Weight inversely by assignment count (not sample_count) so pending
      # assignments are accounted for, avoiding skew under load.
      assignment_counts = AbTestAssignment.where(ab_test: ab_test, ab_test_variant: variants)
                                          .group(:ab_test_variant_id)
                                          .count
      max_count = variants.map { |v| assignment_counts[v.id] || 0 }.max
      weights = variants.map do |v|
        count = assignment_counts[v.id] || 0
        (max_count - count) + 1
      end
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
