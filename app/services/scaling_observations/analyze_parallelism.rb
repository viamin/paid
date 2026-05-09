# frozen_string_literal: true

module ScalingObservations
  class AnalyzeParallelism
    Result = Struct.new(
      :status,
      :sample_count,
      :recommended_agent_count,
      :recommended_max_batch_size,
      :diminishing_returns_at,
      :threshold_signal_at,
      :allocator_decision,
      :values,
      keyword_init: true
    ) do
      def to_h
        {
          "status" => status,
          "sample_count" => sample_count,
          "recommended_agent_count" => recommended_agent_count,
          "recommended_max_batch_size" => recommended_max_batch_size,
          "diminishing_returns_at" => diminishing_returns_at,
          "threshold_signal_at" => threshold_signal_at,
          "allocator_decision" => allocator_decision,
          "values" => values
        }.compact
      end
    end

    MIN_DURATION_IMPROVEMENT_RATIO = 0.10
    SUCCESS_RATE_DROP_THRESHOLD = 0.15
    BLOCKED_RATE_THRESHOLD = 0.20
    LAUNCH_RATE_THRESHOLD = 0.85

    def self.call(...)
      new(...).call
    end

    def initialize(observations:, min_samples: 2)
      @observations = Array(observations).select(&:parallel_execution)
      @min_samples = min_samples.to_i
    end

    def call
      return Result.new(status: "insufficient_data", sample_count: 0, values: []) if grouped_values.empty?

      Result.new(
        status: analysis_status,
        sample_count: grouped_values.sum { |value| value["sample_count"] },
        recommended_agent_count: recommendation&.fetch("requested_agent_count", nil),
        recommended_max_batch_size: recommendation&.fetch("max_batch_size", nil),
        diminishing_returns_at: diminishing_returns_at,
        threshold_signal_at: threshold_signal_at,
        allocator_decision: recommendation,
        values: grouped_values
      )
    end

    private

    attr_reader :observations, :min_samples

    def grouped_values
      @grouped_values ||= begin
        grouped = observations.group_by { |observation| observation.agent_count_planned.to_i }
        summaries = []

        grouped.keys.sort.each do |agent_count|
          rows = grouped.fetch(agent_count)
          previous = summaries.last

          summaries << build_value_summary(agent_count:, rows:, previous:)
        end

        summaries
      end
    end

    def analysis_status
      return "insufficient_data" if viable_values.empty?
      return "ready" if recommendation.present?

      "collecting"
    end

    def viable_values
      @viable_values ||= grouped_values.select { |value| value["sample_count"] >= min_samples }
    end

    def diminishing_returns_at
      grouped_values.find { |value| value["signals"].include?("diminishing_returns") }
        &.fetch("agent_count", nil)
    end

    def threshold_signal_at
      grouped_values.find do |value|
        value["signals"].any? { |signal| signal != "diminishing_returns" }
      end&.fetch("agent_count", nil)
    end

    def recommendation
      return @recommendation if defined?(@recommendation)

      @recommendation = begin
        candidate = recommendable_values.max_by do |value|
          [
            value["success_rate"],
            -value["avg_duration_seconds"],
            -value["avg_cost_cents"],
            -value["avg_parallelism_observed"],
            -value["agent_count"]
          ]
        end
        if candidate
          {
            "requested_agent_count" => candidate["agent_count"],
            "max_batch_size" => candidate["agent_count"],
            "reason" => recommendation_reason(candidate),
            "confidence" => confidence_for(candidate)
          }
        end
      end
    end

    def recommendable_values
      @recommendable_values ||= viable_values.reject do |value|
        value["signals"].any? { |signal| signal != "diminishing_returns" }
      end.reject do |value|
        value["signals"].include?("diminishing_returns")
      end.presence || viable_values.reject { |value| value["signals"].any? { |signal| signal != "diminishing_returns" } }
    end

    def recommendation_reason(candidate)
      if candidate["signals"].empty?
        "best_success_rate_before_threshold"
      else
        "lowest_risk_viable_parallelism"
      end
    end

    def confidence_for(candidate)
      candidate.fetch("sample_count", 0) >= (min_samples * 2) ? "high" : "medium"
    end

    def build_value_summary(agent_count:, rows:, previous:)
      sample_count = rows.size
      success_rate = rate(rows, &:success)
      avg_duration_seconds = average(rows, &:duration_seconds)
      avg_cost_cents = average(rows, &:total_cost_cents)
      avg_parallelism_observed = average(rows, &:parallelism_observed)
      launch_rate = ratio(
        rows.sum(&:agent_count_launched),
        rows.sum(&:agent_count_planned)
      )
      blocked_rate = ratio(
        rows.sum(&:agent_count_blocked),
        rows.sum(&:agent_count_planned)
      )

      marginal_duration_improvement_ratio = duration_improvement_ratio(previous, avg_duration_seconds)
      signals = build_signals(
        previous: previous,
        success_rate: success_rate,
        blocked_rate: blocked_rate,
        launch_rate: launch_rate,
        marginal_duration_improvement_ratio: marginal_duration_improvement_ratio
      )

      {
        "agent_count" => agent_count,
        "sample_count" => sample_count,
        "success_rate" => success_rate,
        "avg_duration_seconds" => avg_duration_seconds,
        "avg_cost_cents" => avg_cost_cents,
        "avg_parallelism_observed" => avg_parallelism_observed,
        "launch_rate" => launch_rate,
        "blocked_rate" => blocked_rate,
        "marginal_duration_improvement_ratio" => marginal_duration_improvement_ratio,
        "signals" => signals
      }
    end

    def build_signals(previous:, success_rate:, blocked_rate:, launch_rate:, marginal_duration_improvement_ratio:)
      [].tap do |signals|
        if previous && marginal_duration_improvement_ratio && marginal_duration_improvement_ratio <= MIN_DURATION_IMPROVEMENT_RATIO
          signals << "diminishing_returns"
        end
        if previous && success_rate <= previous["success_rate"] - SUCCESS_RATE_DROP_THRESHOLD
          signals << "success_rate_regression"
        end
        signals << "blocked_capacity" if blocked_rate >= BLOCKED_RATE_THRESHOLD
        signals << "launch_shortfall" if launch_rate < LAUNCH_RATE_THRESHOLD
      end
    end

    def duration_improvement_ratio(previous, avg_duration_seconds)
      return unless previous
      return 0.0 if previous["avg_duration_seconds"].zero?

      ((previous["avg_duration_seconds"] - avg_duration_seconds) / previous["avg_duration_seconds"]).round(4)
    end

    def rate(observations)
      return 0.0 if observations.empty?

      (observations.count { |observation| yield(observation) }.to_f / observations.size).round(4)
    end

    def average(observations)
      return 0.0 if observations.empty?

      (observations.sum { |observation| yield(observation).to_f } / observations.size).round(4)
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.to_i <= 0

      (numerator.to_f / denominator).round(4)
    end
  end
end
