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
        "dimension" => assignment.execution_plan["dimension"],
        "assigned_value" => assignment.assigned_value,
        "requested_iteration_count" => assignment.execution_plan["requested_iteration_count"],
        "application_mode" => assignment.execution_plan["application_mode"],
        "status" => scaling_observation.status,
        "success" => scaling_observation.success,
        "parallel_execution" => scaling_observation.parallel_execution,
        "agent_count_planned" => scaling_observation.agent_count_planned,
        "agent_count_launched" => scaling_observation.agent_count_launched,
        "agent_count_succeeded" => scaling_observation.agent_count_succeeded,
        "agent_count_failed" => scaling_observation.agent_count_failed,
        "agent_count_blocked" => scaling_observation.agent_count_blocked,
        "parallelism_observed" => scaling_observation.parallelism_observed,
        "total_iterations" => scaling_observation.total_iterations,
        "max_iterations" => scaling_observation.max_iterations,
        "duration_seconds" => scaling_observation.duration_seconds,
        "total_cost_cents" => scaling_observation.total_cost_cents,
        "total_input_tokens" => scaling_observation.total_input_tokens,
        "total_output_tokens" => scaling_observation.total_output_tokens,
        "child_run_count" => child_runs.size,
        "child_run_metrics" => child_run_metrics,
        "quality_metric_sample_count" => quality_scores.size,
        "avg_quality_score" => average_quality_score
      }
    end

    def child_runs
      @child_runs ||= AgentRun
        .includes(:quality_metrics)
        .where(project_id: scaling_observation.project_id, parent_workflow_id: scaling_observation.workflow_id)
    end

    def quality_scores
      @quality_scores ||= child_runs.filter_map { |run| automated_quality_score_for(run) }
    end

    def average_quality_score
      return nil if quality_scores.empty?

      (quality_scores.sum / quality_scores.size).round(4)
    end

    def child_run_metrics
      child_runs.map do |run|
        {
          "agent_run_id" => run.id,
          "issue_id" => run.issue_id,
          "status" => run.status,
          "iterations" => run.iterations.to_i,
          "duration_seconds" => run.duration_seconds,
          "cost_cents" => run.cost_cents.to_i,
          "tokens_input" => run.tokens_input.to_i,
          "tokens_output" => run.tokens_output.to_i,
          "quality_score" => automated_quality_score_for(run)
        }.compact
      end
    end

    def automated_quality_score_for(run)
      run.quality_metrics.find do |metric|
        metric.metric_type == "automated" && metric.composite_score.present?
      end&.composite_score&.to_f
    end
  end
end
