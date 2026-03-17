# frozen_string_literal: true

module AbTests
  class AssignVariant
    def self.call(...)
      new(...).call
    end

    def initialize(prompt:, agent_run: nil)
      @prompt = prompt
      @agent_run = agent_run
    end

    def call
      test = find_active_test
      return nil unless test

      # Prevent double-assignment for the same agent run
      if agent_run
        existing = AbTestAssignment.find_by(ab_test: test, agent_run: agent_run)
        return existing.ab_test_variant if existing
      end

      variant = select_variant(test)
      return variant unless variant && agent_run

      record_assignment(test, variant)
    end

    private

    attr_reader :prompt, :agent_run

    def find_active_test
      AbTest
        .running
        .where(prompt: prompt)
        .order(created_at: :desc)
        .first
    end

    # Weighted random selection: variants with fewer samples get higher weight
    # to ensure balanced distribution across variants.
    def select_variant(test)
      variants = test.ab_test_variants.to_a
      return nil if variants.empty?

      max_samples = variants.map(&:sample_count).max
      weights = variants.map { |v| [ v, (max_samples - v.sample_count + 1).to_f ] }
      total_weight = weights.sum(&:last)
      roll = rand * total_weight
      cumulative = 0.0

      weights.each do |variant, weight|
        cumulative += weight
        return variant if roll < cumulative
      end

      variants.last
    end

    def record_assignment(test, variant)
      assignment = AbTestAssignment.create!(
        ab_test: test,
        ab_test_variant: variant,
        agent_run: agent_run
      )
      assignment.ab_test_variant
    rescue ActiveRecord::RecordNotUnique
      # Another process already assigned this agent run; return the canonical variant
      AbTestAssignment.find_by!(ab_test: test, agent_run: agent_run).ab_test_variant
    end
  end
end
