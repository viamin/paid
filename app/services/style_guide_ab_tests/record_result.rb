# frozen_string_literal: true

module StyleGuideAbTests
  class RecordResult
    ANALYSIS_INTERVAL = StyleGuideAbTest::ANALYSIS_INTERVAL

    attr_reader :style_guide_ab_test, :agent_run, :quality_score

    def initialize(style_guide_ab_test:, agent_run:, quality_score:)
      @style_guide_ab_test = style_guide_ab_test
      @agent_run = agent_run
      @quality_score = quality_score
    end

    def self.call(...)
      new(...).record
    end

    def record
      validate_quality_score!

      score_recorded = ActiveRecord::Base.transaction do
        updated_count = StyleGuideAbTestAssignment
          .where(style_guide_ab_test: style_guide_ab_test, agent_run: agent_run, quality_score: nil)
          .update_all(quality_score: quality_score, updated_at: Time.current)
        next false if updated_count.zero?

        assignment = StyleGuideAbTestAssignment.find_by!(style_guide_ab_test: style_guide_ab_test, agent_run: agent_run)
        assignment.style_guide_ab_test_variant.record_quality_score!(quality_score)
        true
      end

      check_auto_completion if score_recorded
    end

    private

    def validate_quality_score!
      return if quality_score.is_a?(Numeric) && quality_score.between?(0, 1)

      raise ArgumentError, "quality_score must be a number between 0 and 1"
    end

    def check_auto_completion
      style_guide_ab_test.reload
      return unless style_guide_ab_test.running?
      return unless style_guide_ab_test.sufficient_samples?

      total_samples = style_guide_ab_test.style_guide_ab_test_variants.sum(:sample_count)
      min_required = style_guide_ab_test.min_samples_per_variant * style_guide_ab_test.style_guide_ab_test_variants.count
      return unless total_samples == min_required || (total_samples % ANALYSIS_INTERVAL).zero?

      result = style_guide_ab_test.cached_or_compute_analysis
      return if result.nil? || result.status == :insufficient_data

      if result.status == :winner_found
        style_guide_ab_test.complete!(winner: result.winner)
        StyleGuideAbTests::PromoteWinner.call(style_guide_ab_test: style_guide_ab_test)
      elsif result.status == :control_wins
        style_guide_ab_test.complete!
      end
    rescue ActiveRecord::RecordInvalid
      nil
    end
  end
end
