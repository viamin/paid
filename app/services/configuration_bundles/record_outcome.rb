# frozen_string_literal: true

module ConfigurationBundles
  class RecordOutcome
    attr_reader :agent_run, :quality_metric

    def initialize(agent_run:, quality_metric:)
      @agent_run = agent_run
      @quality_metric = quality_metric
    end

    def self.call(...)
      new(...).call
    end

    def call
      return unless agent_run.configuration_bundle

      outcome = BundleOutcome.find_or_initialize_by(
        configuration_bundle: agent_run.configuration_bundle,
        agent_run: agent_run
      )
      outcome.assign_attributes(
        quality_score: quality_metric.composite_score,
        cost_cents: agent_run.cost_cents.to_i,
        duration_seconds: agent_run.duration_seconds,
        tokens_used: agent_run.tokens_input.to_i + agent_run.tokens_output.to_i,
        success: agent_run.status == "completed",
        metrics: {
          "component_scores" => quality_metric.scores || {},
          "completed_at" => agent_run.completed_at&.iso8601,
          "status" => agent_run.status
        }
      )
      outcome.save!
      outcome
    end
  end
end
