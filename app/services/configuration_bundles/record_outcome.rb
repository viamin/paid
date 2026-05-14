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

      tokens_input = agent_run.tokens_input.to_i
      tokens_output = agent_run.tokens_output.to_i
      queue_duration_seconds = duration_between(agent_run.created_at, agent_run.started_at)
      total_duration_seconds = duration_between(agent_run.created_at, agent_run.completed_at)
      objective_result = ConfigurationBundles::ObjectiveScore.call(
        project: agent_run.project,
        quality_score: quality_metric.composite_score,
        cost_cents: agent_run.cost_cents,
        duration_seconds: agent_run.duration_seconds
      )

      outcome = BundleOutcome.find_or_initialize_by(
        configuration_bundle: agent_run.configuration_bundle,
        agent_run: agent_run
      )
      outcome.assign_attributes(
        quality_score: quality_metric.composite_score,
        cost_cents: agent_run.cost_cents.to_i,
        duration_seconds: agent_run.duration_seconds,
        tokens_used: tokens_input + tokens_output,
        success: agent_run.status == "completed",
        metrics: {
          "component_scores" => quality_metric.scores || {},
          "completed_at" => agent_run.completed_at&.iso8601,
          "created_at" => agent_run.created_at&.iso8601,
          "cost_score" => objective_result.cost_score,
          "execution_duration_seconds" => agent_run.duration_seconds,
          "exploratory" => case agent_run.configuration_bundle_selection_mode
                           when "exploratory" then true
                           when "exploitative" then false
                           end,
          "outcome" => agent_run.status,
          "objective_score" => objective_result.objective_score,
          "quality_per_dollar" => objective_result.quality_per_dollar,
          "queue_duration_seconds" => queue_duration_seconds,
          "selection_context" => agent_run.configuration_bundle_selection_context,
          "selection_mode" => agent_run.configuration_bundle_selection_mode,
          "speed_score" => objective_result.speed_score,
          "started_at" => agent_run.started_at&.iso8601,
          "status" => agent_run.status,
          "success" => agent_run.status == "completed",
          "tokens_input" => tokens_input,
          "tokens_output" => tokens_output,
          "total_duration_seconds" => total_duration_seconds
        }.compact
      )
      outcome.save!
      outcome
    end

    private

    def duration_between(start_time, end_time)
      return unless start_time && end_time

      [ (end_time - start_time).round, 0 ].max
    end
  end
end
