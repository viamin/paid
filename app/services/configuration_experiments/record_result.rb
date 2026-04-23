# frozen_string_literal: true

module ConfigurationExperiments
  class RecordResult
    attr_reader :configuration_experiment, :agent_run, :quality_score

    def initialize(configuration_experiment:, agent_run:, quality_score:)
      @configuration_experiment = configuration_experiment
      @agent_run = agent_run
      @quality_score = quality_score
    end

    def self.call(...)
      new(...).record
    end

    def record
      validate_quality_score!

      score_recorded = ActiveRecord::Base.transaction do
        updated_count = ConfigurationExperimentAssignment
          .where(configuration_experiment: configuration_experiment, agent_run: agent_run, quality_score: nil)
          .update_all(quality_score: quality_score, updated_at: Time.current)
        next false unless updated_count > 0

        assignment = ConfigurationExperimentAssignment.find_by!(
          configuration_experiment: configuration_experiment,
          agent_run: agent_run
        )
        assignment.configuration_experiment_variant.record_quality_score!(quality_score)
        true
      end

      check_auto_completion(configuration_experiment) if score_recorded
    end

    private

    ANALYSIS_INTERVAL = ConfigurationExperiment::ANALYSIS_INTERVAL

    def validate_quality_score!
      unless quality_score.is_a?(Numeric) && quality_score >= 0 && quality_score <= 1
        raise ArgumentError, "quality_score must be a number between 0 and 1"
      end
    end

    def check_auto_completion(configuration_experiment)
      configuration_experiment.reload
      return unless configuration_experiment.running?
      return unless configuration_experiment.sufficient_samples?
      return unless should_analyze?(configuration_experiment)

      result = configuration_experiment.cached_or_compute_analysis
      return if result.status == :insufficient_data

      if result.status == :winner_found
        configuration_experiment.complete!(winner: result.winner)
      elsif result.status == :control_wins
        configuration_experiment.complete!
      end
    rescue ActiveRecord::RecordInvalid
      nil
    end

    def should_analyze?(configuration_experiment)
      total_samples = configuration_experiment.configuration_experiment_variants.sum(:sample_count)
      min_required = configuration_experiment.min_samples_per_variant * configuration_experiment.configuration_experiment_variants.count
      total_samples == min_required || (total_samples % ANALYSIS_INTERVAL).zero?
    end
  end
end
