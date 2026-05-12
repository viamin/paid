# frozen_string_literal: true

module CoordinationExperiments
  class PromotionReadiness
    Result = Struct.new(:status, :candidate, :control_summary, :candidate_summary, :reasons, keyword_init: true)

    MIN_COORDINATION_SCORE_DELTA = 0.0
    MAX_COST_INCREASE_RATIO = 1.1
    MAX_DURATION_INCREASE_RATIO = 1.2
    MAX_CONFLICT_RATE_INCREASE = 0.1
    MAX_MANUAL_REVIEW_RATE_INCREASE = 0.1
    MIN_SUCCESS_RATE_DELTA = -0.05
    MIN_COMPLETION_RATE_DELTA = -0.05
    MAX_FAILED_TASK_RATE_INCREASE = 0.1
    MAX_DEPENDENCY_FAILURE_RATE_INCREASE = 0.1

    def self.call(...)
      new(...).call
    end

    def initialize(coordination_experiment:)
      @coordination_experiment = coordination_experiment
    end

    def call
      return Result.new(status: :more_data_needed, reasons: [ "insufficient_samples" ]) unless enough_samples?

      candidate = variants.reject(&:is_control).max_by(&:avg_coordination_score)
      return Result.new(status: :no_candidate, reasons: [ "no_variant_candidate" ]) unless candidate

      control_summary = summarize(control_variant)
      candidate_summary = summarize(candidate)
      reasons = guardrail_failures(control_summary:, candidate_summary:)

      status = reasons.empty? ? :ready : :guardrail_failed
      Result.new(status:, candidate:, control_summary:, candidate_summary:, reasons:)
    end

    private

    attr_reader :coordination_experiment

    def variants
      @variants ||= coordination_experiment.coordination_experiment_variants.order(:id).to_a
    end

    def control_variant
      @control_variant ||= variants.find(&:is_control)
    end

    def enough_samples?
      variants.present? && variants.all? { |variant| variant.sample_count >= coordination_experiment.min_samples_per_variant }
    end

    def summarize(variant)
      assignments = variant.coordination_experiment_assignments.recorded.to_a
      metrics = assignments.map(&:outcome_metrics)
      total_tasks = summed(metrics) { |metric| metric["task_count"] }
      total_cost_cents = summed(metrics) { |metric| metric["total_cost_cents"] }
      total_duration_seconds = summed(metrics) { |metric| metric["total_duration_seconds"] }

      {
        sample_count: assignments.size,
        total_task_count: total_tasks,
        avg_coordination_score: variant.avg_coordination_score.to_f,
        success_rate: rate(metrics) { |metric| metric["success"] },
        completion_rate: ratio(metrics, denominator: total_tasks) { |metric| metric["completed_tasks"] },
        failed_task_rate: ratio(metrics, denominator: total_tasks) { |metric| metric["failed_tasks"] },
        dependency_failed_task_rate: ratio(metrics, denominator: total_tasks) { |metric| metric["dependency_failed_tasks"] },
        conflict_rate: rate(metrics) { |metric| metric["conflict_detected"] },
        manual_review_rate: rate(metrics) { |metric| metric["manual_review_required"] },
        avg_cost_cents: average_metric(metrics) { |metric| metric["total_cost_cents"].to_f },
        avg_duration_seconds: average_metric(metrics) { |metric| metric["total_duration_seconds"].to_f },
        avg_cost_per_task_cents: average_total(total_cost_cents, total_tasks),
        avg_duration_per_task_seconds: average_total(total_duration_seconds, total_tasks),
        aggregated_pr_rate: rate(metrics) { |metric| metric["aggregated_pr_created"] }
      }
    end

    def guardrail_failures(control_summary:, candidate_summary:)
      failures = []

      if candidate_summary[:avg_coordination_score] < control_summary[:avg_coordination_score] + MIN_COORDINATION_SCORE_DELTA
        failures << "coordination_score_not_improved"
      end

      if candidate_summary[:success_rate] < control_summary[:success_rate] + MIN_SUCCESS_RATE_DELTA
        failures << "success_rate_regressed"
      end

      if candidate_summary[:completion_rate] < control_summary[:completion_rate] + MIN_COMPLETION_RATE_DELTA
        failures << "completion_rate_regressed"
      end

      if candidate_summary[:failed_task_rate] > control_summary[:failed_task_rate] + MAX_FAILED_TASK_RATE_INCREASE
        failures << "failed_task_rate_too_high"
      end

      if candidate_summary[:dependency_failed_task_rate] > control_summary[:dependency_failed_task_rate] + MAX_DEPENDENCY_FAILURE_RATE_INCREASE
        failures << "dependency_failure_rate_too_high"
      end

      if candidate_summary[:conflict_rate] > control_summary[:conflict_rate] + MAX_CONFLICT_RATE_INCREASE
        failures << "conflict_rate_too_high"
      end

      if candidate_summary[:manual_review_rate] > control_summary[:manual_review_rate] + MAX_MANUAL_REVIEW_RATE_INCREASE
        failures << "manual_review_rate_too_high"
      end

      control_cost = control_summary[:avg_cost_per_task_cents]
      if control_cost.positive? && candidate_summary[:avg_cost_per_task_cents] > (control_cost * MAX_COST_INCREASE_RATIO)
        failures << "cost_increase_too_high"
      end

      control_duration = control_summary[:avg_duration_per_task_seconds]
      if control_duration.positive? && candidate_summary[:avg_duration_per_task_seconds] > (control_duration * MAX_DURATION_INCREASE_RATIO)
        failures << "duration_increase_too_high"
      end

      failures
    end

    def rate(metrics)
      return 0.0 if metrics.empty?

      metrics.count { |metric| yield(metric) }.to_f / metrics.size
    end

    def average_metric(metrics)
      return 0.0 if metrics.empty?

      metrics.sum { |metric| yield(metric) } / metrics.size
    end

    def ratio(metrics, denominator:)
      return 0.0 if denominator.to_i <= 0

      summed(metrics) { |metric| yield(metric) }.to_f / denominator
    end

    def summed(metrics)
      metrics.sum { |metric| yield(metric).to_i }
    end

    def average_total(total, count)
      return 0.0 if count.to_i <= 0

      total.to_f / count
    end
  end
end
