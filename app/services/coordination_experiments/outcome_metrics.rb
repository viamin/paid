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
      {
        "task_count" => task_count,
        "parallel_execution" => parallel_execution,
        "completed_tasks" => result.fetch(:completed, 0).to_i,
        "failed_tasks" => result.fetch(:failed, 0).to_i,
        "success" => !!result[:success],
        "queued_tasks" => child_results.count { |child| child[:queued] },
        "dependency_failed_tasks" => child_results.count { |child| child[:error] == "dependencies_failed" },
        "policy_cancelled_tasks" => child_results.count { |child| child[:error] == "cancelled_by_policy" },
        "conflict_detected" => !!result.dig(:conflicts, :has_conflicts),
        "manual_review_required" => !!result.dig(:conflicts, :requires_manual_review),
        "aggregated_pr_created" => result[:aggregated_pr].present?
      }
    end

    def run_metrics
      runs = AgentRun.where(id: successful_run_ids)
      {
        "successful_run_count" => successful_run_ids.size,
        "total_cost_cents" => runs.sum(:cost_cents).to_i,
        "total_duration_seconds" => runs.sum(:duration_seconds).to_i,
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
  end
end
