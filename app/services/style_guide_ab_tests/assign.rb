# frozen_string_literal: true

module StyleGuideAbTests
  class Assign
    attr_reader :style_guide_ab_test, :agent_run

    def initialize(style_guide_ab_test:, agent_run:)
      @style_guide_ab_test = style_guide_ab_test
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).assign
    end

    def assign
      raise ArgumentError, "A/B test is not running" unless style_guide_ab_test.running?

      existing = StyleGuideAbTestAssignment.find_by(style_guide_ab_test: style_guide_ab_test, agent_run: agent_run)
      return existing if existing

      variant = select_variant

      StyleGuideAbTestAssignment.create!(
        style_guide_ab_test: style_guide_ab_test,
        style_guide_ab_test_variant: variant,
        agent_run: agent_run
      )
    rescue ActiveRecord::RecordNotUnique
      StyleGuideAbTestAssignment.find_by!(style_guide_ab_test: style_guide_ab_test, agent_run: agent_run)
    end

    private

    def select_variant
      variants = style_guide_ab_test.style_guide_ab_test_variants.order(:id).to_a
      raise ArgumentError, "A/B test has no variants" if variants.empty?
      return variants.first if variants.one?

      assignment_counts = StyleGuideAbTestAssignment.where(
        style_guide_ab_test: style_guide_ab_test,
        style_guide_ab_test_variant: variants
      ).group(:style_guide_ab_test_variant_id).count
      max_count = variants.map { |variant| assignment_counts[variant.id] || 0 }.max
      weights = variants.map do |variant|
        count = assignment_counts[variant.id] || 0
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
