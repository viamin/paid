# frozen_string_literal: true

module AbTests
  # Records a quality score for an A/B test assignment and updates
  # variant aggregates. Optionally checks for auto-completion when
  # sufficient samples have been gathered.
  #
  # The atomic-claim + variant aggregate update pattern is shared with
  # ConfigurationExperiments::RecordResult, StrategyExperiments::RecordResult,
  # and StyleGuideAbTests::RecordResult. The auto-completion loop is shared
  # via Experiments::Lifecycle.
  #
  # @example
  #   AbTests::RecordResult.call(ab_test: test, agent_run: run, quality_score: 0.85)
  class RecordResult
    ANALYSIS_INTERVAL = AbTest::ANALYSIS_INTERVAL

    attr_reader :ab_test, :agent_run, :quality_score

    def initialize(ab_test:, agent_run:, quality_score:)
      @ab_test = ab_test
      @agent_run = agent_run
      @quality_score = quality_score
    end

    def self.call(...)
      new(...).record
    end

    def record
      Experiments::VariantScoreAggregator::ScoreValidations.validate!(quality_score)

      score_recorded = ActiveRecord::Base.transaction { claim_assignment_and_record }
      Experiments::Lifecycle.maybe_complete(
        ab_test,
        score_recorded: score_recorded,
        analysis_interval: ANALYSIS_INTERVAL
      )
    end

    private

    # Atomic claim prevents double-counting when two processes record the
    # same agent_run concurrently.
    def claim_assignment_and_record
      updated_count = AbTestAssignment
        .where(ab_test: ab_test, agent_run: agent_run, quality_score: nil)
        .update_all(quality_score: quality_score, updated_at: Time.current)
      return false unless updated_count.positive?

      assignment = AbTestAssignment.find_by!(ab_test: ab_test, agent_run: agent_run)
      variant = assignment.ab_test_variant
      variant.with_lock do
        Experiments::VariantScoreAggregator.increment_for_score!(variant, quality_score)
        variant.save!
      end
      true
    end
  end
end
