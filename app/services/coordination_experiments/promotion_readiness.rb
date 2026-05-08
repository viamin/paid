# frozen_string_literal: true

module CoordinationExperiments
  class PromotionReadiness
    Result = Struct.new(:status, :candidate, :control_summary, :candidate_summary, :reasons, keyword_init: true)

    MAX_COST_INCREASE_RATIO = 1.1
    MAX_CONFLICT_RATE_INCREASE = 0.1
    MAX_MANUAL_REVIEW_RATE_INCREASE = 0.1
    MIN_SUCCESS_RATE_DELTA = -0.05

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
      {
        sample_count: assignments.size,
        avg_coordination_score: variant.avg_coordination_score.to_f,
        success_rate: rate(metrics) { |metric| metric["success"] },
        conflict_rate: rate(metrics) { |metric| metric["conflict_detected"] },
        manual_review_rate: rate(metrics) { |metric| metric["manual_review_required"] },
        avg_cost_cents: average(metrics) { |metric| metric["total_cost_cents"].to_f }
      }
    end

    def guardrail_failures(control_summary:, candidate_summary:)
      failures = []

      if candidate_summary[:success_rate] < control_summary[:success_rate] + MIN_SUCCESS_RATE_DELTA
        failures << "success_rate_regressed"
      end

      if candidate_summary[:conflict_rate] > control_summary[:conflict_rate] + MAX_CONFLICT_RATE_INCREASE
        failures << "conflict_rate_too_high"
      end

      if candidate_summary[:manual_review_rate] > control_summary[:manual_review_rate] + MAX_MANUAL_REVIEW_RATE_INCREASE
        failures << "manual_review_rate_too_high"
      end

      control_cost = control_summary[:avg_cost_cents]
      if control_cost.positive? && candidate_summary[:avg_cost_cents] > (control_cost * MAX_COST_INCREASE_RATIO)
        failures << "cost_increase_too_high"
      end

      failures
    end

    def rate(metrics)
      return 0.0 if metrics.empty?

      metrics.count { |metric| yield(metric) }.to_f / metrics.size
    end

    def average(metrics)
      return 0.0 if metrics.empty?

      metrics.sum { |metric| yield(metric) } / metrics.size
    end
  end
end
