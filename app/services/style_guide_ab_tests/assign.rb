# frozen_string_literal: true

module StyleGuideAbTests
  # Assigns an agent run to a style guide A/B test variant using weighted
  # random selection that favours underfilled variants to keep the cohort
  # balanced.
  #
  # The variant-selection math lives in Experiments::AssignmentPicker; this
  # service owns the experiment-specific invariant lookup and assignment
  # row creation.
  #
  # @spec STYLE-GUIDE-EVOLUTION-005
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
      counts = StyleGuideAbTestAssignment.where(
        style_guide_ab_test: style_guide_ab_test,
        style_guide_ab_test_variant: variants
      ).group(:style_guide_ab_test_variant_id).count

      Experiments::AssignmentPicker.pick(
        variants: variants,
        counts: counts,
        strategy: :inversely_weighted
      )
    end
  end
end
