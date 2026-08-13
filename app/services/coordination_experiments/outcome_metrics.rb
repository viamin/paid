# frozen_string_literal: true

module CoordinationExperiments
  class OutcomeMetrics
    Result = Struct.new(:metrics, :coordination_score, keyword_init: true)

    CONFLICT_PENALTY = 0.15
    MANUAL_REVIEW_PENALTY = 0.15
    DEPENDENCY_FAILURE_WEIGHT = 0.2
    FAILED_TASK_WEIGHT = 0.35

    def self.call(...)
      new(...).call
    end

    def initialize(task_count:, parallel_execution:, result:)
      @task_count = task_count.to_i
      @parallel_execution = parallel_execution
      @result = (result || {}).deep_symbolize_keys
    end

    def call
      metrics = base_metrics.merge(run_metrics)
      Result.new(metrics:, coordination_score: coordination_score_for(metrics))
    end

    private

    attr_reader :task_count, :parallel_execution, :result

    def base_metrics
      total_tasks = [ task_count, 1 ].max.to_f
      completed_tasks = result.fetch(:completed, 0).to_i
      failed_tasks = result.fetch(:failed, 0).to_i
      queued_tasks = child_results.count { |child| child[:queued] }
      dependency_failed_tasks = child_results.count { |child| child[:error] == "dependencies_failed" }
      policy_cancelled_tasks = child_results.count { |child| child[:error] == "cancelled_by_policy" }

      {
        "summary_version" => 1,
        "task_count" => task_count,
        "parallel_execution" => parallel_execution,
        "completed_tasks" => completed_tasks,
        "failed_tasks" => failed_tasks,
        "success" => !!result[:success],
        "queued_tasks" => queued_tasks,
        "dependency_failed_tasks" => dependency_failed_tasks,
        "policy_cancelled_tasks" => policy_cancelled_tasks,
        "completion_rate" => (completed_tasks / total_tasks).round(4),
        "failed_task_rate" => (failed_tasks / total_tasks).round(4),
        "queued_task_rate" => (queued_tasks / total_tasks).round(4),
        "dependency_failed_task_rate" => (dependency_failed_tasks / total_tasks).round(4),
        "policy_cancelled_task_rate" => (policy_cancelled_tasks / total_tasks).round(4),
        "conflict_detected" => !!result.dig(:conflicts, :has_conflicts),
        "manual_review_required" => !!result.dig(:conflicts, :requires_manual_review),
        "aggregated_pr_created" => result[:aggregated_pr].present?
      }
    end

    def run_metrics
      runs = AgentRun.where(id: successful_run_ids)
      successful_run_count = successful_run_ids.size
      total_cost_cents = runs.sum(:cost_cents).to_i
      total_duration_seconds = runs.sum(:duration_seconds).to_i
      {
        "child_run_count" => child_results.size,
        "successful_run_count" => successful_run_count,
        "successful_run_rate" => rate(successful_run_count, child_results.size),
        "total_cost_cents" => total_cost_cents,
        "total_duration_seconds" => total_duration_seconds,
        "avg_cost_per_task_cents" => average(total_cost_cents, task_count),
        "avg_cost_per_successful_run_cents" => average(total_cost_cents, successful_run_count),
        "avg_duration_per_task_seconds" => average(total_duration_seconds, task_count),
        "avg_duration_per_successful_run_seconds" => average(total_duration_seconds, successful_run_count),
        "avg_iterations" => runs.average(:iterations).to_f.round(4)
      }
    end

    def coordination_score_for(metrics)
      total = [ metrics["task_count"], 1 ].max.to_f
      success_ratio = metrics["completed_tasks"].to_f / total
      failure_ratio = metrics["failed_tasks"].to_f / total
      dependency_ratio = metrics["dependency_failed_tasks"].to_f / total

      score = success_ratio
      score -= failure_ratio * FAILED_TASK_WEIGHT
      score -= dependency_ratio * DEPENDENCY_FAILURE_WEIGHT
      score -= CONFLICT_PENALTY if metrics["conflict_detected"]
      score -= MANUAL_REVIEW_PENALTY if metrics["manual_review_required"]

      score.clamp(0.0, 1.0).round(4)
    end

    def child_results
      Array(result[:results]).map(&:deep_symbolize_keys)
    end

    def successful_run_ids
      child_results.filter_map do |child|
        child[:agent_run_id] if child[:success]
      end
    end

    def rate(numerator, denominator)
      return 0.0 if denominator.to_i <= 0

      (numerator.to_f / denominator).round(4)
    end

    def average(total, count)
      return 0.0 if count.to_i <= 0

      (total.to_f / count).round(4)
    end
  end
end
