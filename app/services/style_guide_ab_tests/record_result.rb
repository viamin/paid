# frozen_string_literal: true

module StyleGuideAbTests
  class RecordResult
    ANALYSIS_INTERVAL = StyleGuideAbTest::ANALYSIS_INTERVAL

    attr_reader :style_guide_ab_test, :agent_run, :quality_score, :update_existing

    def initialize(style_guide_ab_test:, agent_run:, quality_score:, update_existing: false)
      @style_guide_ab_test = style_guide_ab_test
      @agent_run = agent_run
      @quality_score = quality_score
      @update_existing = update_existing
    end

    def self.call(...)
      new(...).record
    end

    # @spec STYLE-GUIDE-EVOLUTION-011
    def record
      validate_quality_score!

      score_recorded = ActiveRecord::Base.transaction { record_assignment_score }

      check_auto_completion if score_recorded
    end

    private

    def validate_quality_score!
      return if quality_score.is_a?(Numeric) && quality_score.between?(0, 1)

      raise ArgumentError, "quality_score must be a number between 0 and 1"
    end

    def record_assignment_score
      assignment = StyleGuideAbTestAssignment.find_by!(
        style_guide_ab_test: style_guide_ab_test,
        agent_run: agent_run
      )
      variant = assignment.style_guide_ab_test_variant

      variant.with_lock do
        assignment.reload
        old_score = assignment.quality_score
        return false if old_score.present? && !update_existing

        assignment.update!(quality_score: quality_score)
        if old_score.present?
          adjust_variant_aggregates(variant, old_score:, new_score: quality_score)
          clear_analysis_cache
        else
          add_variant_score(variant, quality_score)
        end

        true
      end
    end

    # @spec STYLE-GUIDE-EVOLUTION-012
    def check_auto_completion
      style_guide_ab_test.reload
      return unless style_guide_ab_test.running?
      return unless style_guide_ab_test.sufficient_samples?
      return unless should_analyze?
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

    def add_variant_score(variant, score)
      score_decimal = BigDecimal(score.to_s)
      variant.sample_count += 1
      variant.total_quality_score = (variant.total_quality_score || BigDecimal("0")) + score_decimal
      variant.avg_quality_score = variant.total_quality_score / variant.sample_count
      variant.save!
    end

    def adjust_variant_aggregates(variant, old_score:, new_score:)
      old_decimal = BigDecimal(old_score.to_s)
      new_decimal = BigDecimal(new_score.to_s)
      variant.total_quality_score = (variant.total_quality_score || BigDecimal("0")) - old_decimal + new_decimal
      variant.avg_quality_score = variant.sample_count.positive? ? variant.total_quality_score / variant.sample_count : nil
      variant.save!
    end

    def clear_analysis_cache
      style_guide_ab_test.update_columns(cached_analysis: nil, analysis_samples_key: nil)
    end

    def should_analyze?
      return true if update_existing

      total_samples = style_guide_ab_test.style_guide_ab_test_variants.sum(:sample_count)
      min_required = style_guide_ab_test.min_samples_per_variant * style_guide_ab_test.style_guide_ab_test_variants.count
      total_samples == min_required || (total_samples % ANALYSIS_INTERVAL).zero?
    end
  end
end
