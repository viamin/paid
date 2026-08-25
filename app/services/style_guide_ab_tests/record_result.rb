# frozen_string_literal: true

module StyleGuideAbTests
  # Records a quality score for a style guide A/B test assignment and
  # updates variant aggregates. Supports re-recording an updated score
  # via `update_existing: true` (used when the underlying signal is
  # corrected).
  #
  # The atomic-claim + variant aggregate update pattern is shared with
  # AbTests::RecordResult, ConfigurationExperiments::RecordResult, and
  # StrategyExperiments::RecordResult. The auto-completion loop is shared
  # via Experiments::Lifecycle, with a style-guide-specific on-complete
  # hook that auto-promotes the winning style guide version once an
  # experiment finishes with a winner.
  #
  # @spec STYLE-GUIDE-EVOLUTION-011
  # @spec STYLE-GUIDE-EVOLUTION-012
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

    def record
      Experiments::VariantScoreAggregator::ScoreValidations.validate!(quality_score)

      score_recorded = ActiveRecord::Base.transaction { record_assignment_score }
      Experiments::Lifecycle.maybe_complete(
        style_guide_ab_test,
        score_recorded: score_recorded,
        analysis_interval: ANALYSIS_INTERVAL,
        force_analysis: update_existing,
        on_complete: method(:promote_winner_on_complete)
      )
    end

    private

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
          Experiments::VariantScoreAggregator.replace_score!(variant, old_score:, new_score: quality_score)
          clear_analysis_cache
        else
          Experiments::VariantScoreAggregator.increment_for_score!(variant, quality_score)
        end
        variant.save!
        true
      end
    end

    def clear_analysis_cache
      style_guide_ab_test.update_columns(cached_analysis: nil, analysis_samples_key: nil)
    end

    def promote_winner_on_complete(freshly_completed)
      return unless freshly_completed.winner_variant

      StyleGuideAbTests::PromoteWinner.call(style_guide_ab_test: freshly_completed)
    end
  end
end
