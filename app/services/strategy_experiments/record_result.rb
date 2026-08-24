# frozen_string_literal: true

module StrategyExperiments
  # Records a quality score for a strategy experiment assignment and
  # updates variant aggregates. Supports re-recording an updated score via
  # `update_existing: true` (used when the underlying signal is corrected).
  #
  # The atomic-claim + variant aggregate update pattern is shared with
  # AbTests::RecordResult, ConfigurationExperiments::RecordResult, and
  # StyleGuideAbTests::RecordResult. The auto-completion loop is shared
  # via Experiments::Lifecycle.
  class RecordResult
    ANALYSIS_INTERVAL = StrategyExperiment::ANALYSIS_INTERVAL

    attr_reader :strategy_experiment, :agent_run, :quality_score, :update_existing

    def initialize(strategy_experiment:, agent_run:, quality_score:, update_existing: false)
      @strategy_experiment = strategy_experiment
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
        strategy_experiment,
        score_recorded: score_recorded,
        analysis_interval: ANALYSIS_INTERVAL,
        force_analysis: update_existing
      )
    end

    private

    def record_assignment_score
      assignment = StrategyExperimentAssignment.find_by!(
        strategy_experiment: strategy_experiment,
        agent_run: agent_run
      )
      variant = assignment.strategy_experiment_variant

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
      strategy_experiment.update_columns(cached_analysis: nil, analysis_samples_key: nil)
    end
  end
end
