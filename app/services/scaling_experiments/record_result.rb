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
        "summary_version" => 1,
        "scaling_experiment_id" => scaling_experiment.id,
        "control_value" => scaling_experiment.control_value,
        "assignment_id" => assignment.id,
        "workflow_id" => assignment.workflow_id,
        "observation_id" => scaling_observation.id,
        "cohort_label" => assignment.execution_plan["cohort_label"],
        "dimension" => assignment.execution_plan["dimension"] || scaling_experiment.dimension,
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
        "total_iterations" => scaling_observation.total_iterations,
        "max_iterations" => scaling_observation.max_iterations,
        "parallelism_planned" => scaling_observation.parallelism_planned,
        "parallelism_observed" => scaling_observation.parallelism_observed,
        "batch_count" => scaling_observation.batch_count,
        "duration_seconds" => scaling_observation.duration_seconds,
        "total_cost_cents" => scaling_observation.total_cost_cents,
        "total_input_tokens" => scaling_observation.total_input_tokens,
        "total_output_tokens" => scaling_observation.total_output_tokens,
        "child_run_count" => child_runs.size,
        "child_run_metrics" => child_run_metrics,
        "agent_launch_success_rate" => agent_launch_success_rate,
        "blocked_task_rate" => blocked_task_rate,
        "quality_metric_sample_count" => quality_scores.size,
        "avg_quality_score" => average_quality_score,
        "execution_plan" => normalized_execution_plan,
        "observation" => observation_snapshot,
        "metrics" => metrics_snapshot
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
          "duration_seconds" => run.duration_seconds.to_f,
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

    def agent_launch_success_rate
      @agent_launch_success_rate ||= begin
        launched = scaling_observation.agent_count_launched.to_i
        if launched.zero?
          0.0
        else
          (scaling_observation.agent_count_succeeded.to_f / launched).round(4)
        end
      end
    end

    def blocked_task_rate
      @blocked_task_rate ||= begin
        task_count = scaling_observation.task_count.to_i
        if task_count.zero?
          0.0
        else
          (scaling_observation.agent_count_blocked.to_f / task_count).round(4)
        end
      end
    end

    def normalized_execution_plan
      assignment.execution_plan.deep_dup
    end

    def observation_snapshot
      {
        "id" => scaling_observation.id,
        "status" => scaling_observation.status,
        "success" => scaling_observation.success,
        "parallel_execution" => scaling_observation.parallel_execution,
        "workflow_name" => scaling_observation.workflow_name,
        "observation_type" => scaling_observation.observation_type,
        "task_count" => scaling_observation.task_count,
        "dependency_edge_count" => scaling_observation.dependency_edge_count
      }
    end

    def metrics_snapshot
      {
        "resource" => {
          "duration_seconds" => scaling_observation.duration_seconds,
          "total_cost_cents" => scaling_observation.total_cost_cents,
          "total_input_tokens" => scaling_observation.total_input_tokens,
          "total_output_tokens" => scaling_observation.total_output_tokens
        },
        "orchestration" => {
          "agent_count_planned" => scaling_observation.agent_count_planned,
          "agent_count_launched" => scaling_observation.agent_count_launched,
          "agent_count_succeeded" => scaling_observation.agent_count_succeeded,
          "agent_count_failed" => scaling_observation.agent_count_failed,
          "agent_count_blocked" => scaling_observation.agent_count_blocked,
          "parallelism_observed" => scaling_observation.parallelism_observed,
          "agent_launch_success_rate" => agent_launch_success_rate,
          "blocked_task_rate" => blocked_task_rate
        },
        "quality" => {
          "sample_count" => quality_scores.size,
          "avg_score" => average_quality_score
        }
      }
    end
  end
end
