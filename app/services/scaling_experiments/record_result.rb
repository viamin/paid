# frozen_string_literal: true

module ScalingExperiments
  class RecordResult
    Result = Struct.new(:assignment, :summary, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(assignment:, scaling_observation:)
      @assignment = assignment
      @scaling_observation = scaling_observation
    end

    def call
      assignment.with_lock do
        assignment.reload
        assignment.update!(
          scaling_observation: scaling_observation,
          outcome_status: outcome_status,
          outcome_summary: build_outcome_summary
        )
      end

      summary = ScalingExperiments::SummarizeResults.call(scaling_experiment: scaling_experiment)
      scaling_experiment.update_columns(cached_summary: summary, summary_samples_key: scaling_experiment.samples_key)
      scaling_experiment.complete! if scaling_experiment.running? && scaling_experiment.sufficient_samples?

      Result.new(assignment:, summary:)
    end

    private

    attr_reader :assignment, :scaling_observation

    def scaling_experiment
      assignment.scaling_experiment
    end

    def outcome_status
      scaling_observation.parallel_execution? ? "recorded" : "skipped"
    end

    def build_outcome_summary
      {
        "observation_id" => scaling_observation.id,
        "cohort_label" => assignment.execution_plan["cohort_label"],
        "status" => scaling_observation.status,
        "success" => scaling_observation.success,
        "parallel_execution" => scaling_observation.parallel_execution,
        "agent_count_planned" => scaling_observation.agent_count_planned,
        "agent_count_launched" => scaling_observation.agent_count_launched,
        "agent_count_succeeded" => scaling_observation.agent_count_succeeded,
        "agent_count_failed" => scaling_observation.agent_count_failed,
        "agent_count_blocked" => scaling_observation.agent_count_blocked,
        "parallelism_observed" => scaling_observation.parallelism_observed,
        "duration_seconds" => scaling_observation.duration_seconds,
        "total_cost_cents" => scaling_observation.total_cost_cents,
        "total_input_tokens" => scaling_observation.total_input_tokens,
        "total_output_tokens" => scaling_observation.total_output_tokens
      }
    end
  end
end
