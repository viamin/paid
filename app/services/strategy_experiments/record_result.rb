# frozen_string_literal: true

module StrategyExperiments
  class RecordResult
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
      validate_quality_score!

      score_recorded = ActiveRecord::Base.transaction { record_assignment_score }

      check_auto_completion(strategy_experiment) if score_recorded
    end

    private

    ANALYSIS_INTERVAL = StrategyExperiment::ANALYSIS_INTERVAL

    def record_assignment_score
      assignment = StrategyExperimentAssignment.find_by!(
        strategy_experiment: strategy_experiment,
        agent_run: agent_run
      )
      variant = assignment.strategy_experiment_variant

      variant.with_lock do
        assignment.reload
        old_score = assignment.quality_score
        if old_score.present? && !update_existing
          false
        else
          assignment.update!(quality_score: quality_score)
          if old_score.present?
            adjust_variant_aggregates(variant, old_score: old_score, new_score: quality_score)
            clear_analysis_cache
          else
            add_variant_score(variant, quality_score)
          end

          true
        end
      end
    end

    def validate_quality_score!
      unless quality_score.is_a?(Numeric) && quality_score >= 0 && quality_score <= 1
        raise ArgumentError, "quality_score must be a number between 0 and 1"
      end
    end

    def check_auto_completion(strategy_experiment)
      strategy_experiment.reload
      return unless strategy_experiment.running?
      return unless strategy_experiment.sufficient_samples?
      return unless should_analyze?(strategy_experiment)

      result = strategy_experiment.cached_or_compute_analysis
      return if result.status == :insufficient_data

      if result.status == :winner_found
        strategy_experiment.complete!(winner: result.winner)
      elsif result.status == :control_wins
        strategy_experiment.complete!
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
      strategy_experiment.update_columns(cached_analysis: nil, analysis_samples_key: nil)
    end

    def should_analyze?(strategy_experiment)
      return true if update_existing

      total_samples = strategy_experiment.strategy_experiment_variants.sum(:sample_count)
      min_required = strategy_experiment.min_samples_per_variant * strategy_experiment.strategy_experiment_variants.count
      total_samples == min_required || (total_samples % ANALYSIS_INTERVAL).zero?
    end
  end
end
