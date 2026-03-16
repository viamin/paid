# frozen_string_literal: true

module AbTests
  class AssignVariant
    def self.call(...)
      new(...).call
    end

    def initialize(prompt:, project:, agent_run: nil)
      @prompt = prompt
      @project = project
      @agent_run = agent_run
    end

    def call
      test = find_active_test
      return nil unless test

      # Prevent double-assignment for the same agent run
      if agent_run
        existing = AbTestAssignment.find_by(agent_run: agent_run)
        return existing.ab_test_variant if existing
      end

      # Check traffic percentage
      return nil unless rand(100) < test.traffic_percentage

      variant = select_variant(test)
      record_assignment(test, variant) if variant && agent_run
      variant
    end

    private

    attr_reader :prompt, :project, :agent_run

    def find_active_test
      AbTest
        .running
        .where(prompt: prompt, account_id: project.account_id)
        .order(created_at: :desc)
        .first
    end

    def select_variant(test)
      variants = test.variants.to_a
      return nil if variants.empty?

      total_weight = variants.sum(&:weight)
      roll = rand(total_weight)
      cumulative = 0

      variants.each do |variant|
        cumulative += variant.weight
        return variant if roll < cumulative
      end

      variants.last
    end

    def record_assignment(test, variant)
      AbTestAssignment.create!(
        ab_test: test,
        ab_test_variant: variant,
        agent_run: agent_run
      )
    rescue ActiveRecord::RecordNotUnique
      # Another process already assigned this agent run; safe to ignore
    end
  end
end
