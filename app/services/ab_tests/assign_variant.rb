# frozen_string_literal: true

module AbTests
  class AssignVariant
    def self.call(...)
      new(...).call
    end

    def initialize(prompt:, project:)
      @prompt = prompt
      @project = project
    end

    def call
      test = find_active_test
      return nil unless test

      # Check traffic percentage
      return nil unless rand(100) < test.traffic_percentage

      select_variant(test)
    end

    private

    attr_reader :prompt, :project

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
  end
end
