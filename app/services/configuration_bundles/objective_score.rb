# frozen_string_literal: true

module ConfigurationBundles
  class ObjectiveScore
    MIN_COST_DOLLARS = 0.01

    Result = Struct.new(
      :objective_score,
      :quality_score,
      :cost_score,
      :speed_score,
      :quality_per_dollar,
      keyword_init: true
    )

    attr_reader :project, :quality_score, :cost_cents, :duration_seconds

    def initialize(project:, quality_score:, cost_cents:, duration_seconds:)
      @project = project
      @quality_score = quality_score
      @cost_cents = cost_cents
      @duration_seconds = duration_seconds
    end

    def self.call(...)
      new(...).call
    end

    def self.from_outcome(outcome)
      objective_score = outcome.metrics&.fetch("objective_score", nil)
      return objective_score.to_f if objective_score.present?

      call(
        project: outcome.agent_run.project,
        quality_score: outcome.quality_score,
        cost_cents: outcome.cost_cents,
        duration_seconds: outcome.duration_seconds
      ).objective_score
    end

    def call
      fitness = PromptEvolution::FitnessFunction.call(
        samples: [ sample ],
        weights: objective_weights,
        reference_cost_cents: project_optimizer_setting("reference_cost_cents"),
        reference_duration_seconds: project_optimizer_setting("reference_duration_seconds")
      )

      Result.new(
        objective_score: fitness.composite_fitness,
        quality_score: fitness.quality_score,
        cost_score: fitness.cost_score,
        speed_score: fitness.speed_score,
        quality_per_dollar: quality_per_dollar
      )
    end

    private

    def sample
      {
        composite_score: quality_score,
        cost_cents: cost_cents,
        duration_seconds: duration_seconds
      }
    end

    def objective_weights
      project_optimizer_setting("weights") || PromptEvolution::FitnessFunction::DEFAULT_WEIGHTS
    end

    def quality_per_dollar
      return nil if quality_score.nil? || cost_cents.nil?

      quality_score.to_f / [ cost_cents.to_f / 100.0, MIN_COST_DOLLARS ].max
    end

    def project_optimizer_setting(*path)
      settings = project.fitness_settings
      return unless settings.is_a?(Hash)

      settings.deep_stringify_keys.dig("configuration_bundle_optimizer", *path)
    end
  end
end
