# frozen_string_literal: true

module ScalingExperiments
  class AnalyzeScalingLaw
    Result = Struct.new(
      :status,
      :dimension,
      :primary_metric,
      :objective,
      :sample_count,
      :control_value,
      :leading_value,
      :recommended_value,
      :scaling_exponent,
      :scaling_exponent_confidence_interval,
      :diminishing_returns_at,
      :efficiency_gain_at_recommendation,
      :sample_threshold_review,
      :statistical_rigor,
      :allocator_decision,
      :values,
      keyword_init: true
    ) do
      def to_h
        {
          "status" => status,
          "dimension" => dimension,
          "primary_metric" => primary_metric,
          "objective" => objective,
          "sample_count" => sample_count,
          "control_value" => control_value,
          "leading_value" => leading_value,
          "recommended_value" => recommended_value,
          "scaling_exponent" => scaling_exponent,
          "scaling_exponent_confidence_interval" => scaling_exponent_confidence_interval,
          "diminishing_returns_at" => diminishing_returns_at,
          "efficiency_gain_at_recommendation" => efficiency_gain_at_recommendation,
          "sample_threshold_review" => sample_threshold_review,
          "statistical_rigor" => statistical_rigor,
          "allocator_decision" => allocator_decision,
          "values" => values
        }.compact
      end
    end

    MIN_SAMPLES = 2
    RDR_TARGET_MIN_SAMPLES_PER_VALUE = 30
    DIMINISHING_RETURNS_RATIO = 0.10
    MIN_EFFICIENCY_GAIN = 0.10
    MAX_ACTIONABLE_INTERVAL_WIDTH_RATIO = 0.5

    METRIC_KEY_TO_SUMMARY_FIELD = {
      "duration_seconds" => "avg_duration_seconds",
      "total_cost_cents" => "avg_cost_cents",
      "parallelism_observed" => "avg_parallelism_observed"
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(scaling_experiment:, value_summaries:, confidence_level: 0.95)
      @scaling_experiment = scaling_experiment
      @value_summaries = Array(value_summaries)
      @confidence_level = confidence_level.to_f
    end

    def call
      return empty_result if control_summary.blank?

      Result.new(
        status: analysis_status,
        dimension: scaling_experiment.dimension,
        primary_metric: primary_metric_key,
        objective: primary_metric_objective,
        sample_count: analyzed_values.sum { |value| value["sample_count"] },
        control_value: scaling_experiment.control_value,
        leading_value: leading_summary&.fetch("assigned_value", nil),
        recommended_value: recommended_summary&.fetch("assigned_value", nil),
        scaling_exponent: scaling_exponent,
        scaling_exponent_confidence_interval: scaling_exponent_confidence_interval,
        diminishing_returns_at: diminishing_returns_at,
        efficiency_gain_at_recommendation: recommended_summary&.fetch("efficiency_gain_vs_control", nil),
        sample_threshold_review: sample_threshold_review,
        statistical_rigor: statistical_rigor,
        allocator_decision: allocator_decision,
        values: analyzed_values
      )
    end

    private

    attr_reader :scaling_experiment, :value_summaries, :confidence_level

    def empty_result
      Result.new(
        status: "insufficient_data",
        dimension: scaling_experiment.dimension,
        primary_metric: primary_metric_key,
        objective: primary_metric_objective,
        sample_count: 0,
        control_value: scaling_experiment.control_value,
        sample_threshold_review: sample_threshold_review,
        statistical_rigor: statistical_rigor,
        values: []
      )
    end

    def analysis_status
      return "insufficient_data" if viable_values.empty?
      return "ready" if recommended_summary.present?

      "collecting"
    end

    def analyzed_values
      @analyzed_values ||= begin
        previous = nil

        normalized_values.map do |summary|
          enriched = enrich_summary(summary, previous:)
          previous = enriched
          enriched
        end
      end
    end

    def normalized_values
      @normalized_values ||= value_summaries
        .map { |summary| summary.deep_dup.stringify_keys }
        .sort_by { |summary| summary["assigned_value"].to_i }
    end

    def control_summary
      @control_summary ||= normalized_values.find do |summary|
        summary["assigned_value"].to_i == scaling_experiment.control_value.to_i
      end
    end

    def viable_values
      @viable_values ||= analyzed_values.select { |summary| summary["sample_count"].to_i >= MIN_SAMPLES }
    end

    def leading_summary
      @leading_summary ||= viable_values.max_by do |summary|
        [
          summary["transformed_primary_metric"].to_f,
          summary["efficiency_score"].to_f,
          summary["sample_count"].to_i
        ]
      end
    end

    def recommended_summary
      return @recommended_summary if defined?(@recommended_summary)

      @recommended_summary = begin
        candidates = viable_values.reject { |summary| blocked_by_signals?(summary) }
        candidates = viable_values if candidates.empty?
        candidates.max_by do |summary|
          [
            summary["efficiency_score"].to_f,
            summary["transformed_primary_metric"].to_f,
            summary["sample_count"].to_i
          ]
        end
      end
    end

    def blocked_by_signals?(summary)
      summary["signals"].include?("diminishing_returns") &&
        summary["efficiency_gain_vs_control"].to_f < MIN_EFFICIENCY_GAIN
    end

    def enrich_summary(summary, previous:)
      primary_value = metric_value(summary, primary_metric_key)
      transformed = transformed_primary_metric(primary_value)
      control_transformed = transformed_primary_metric(metric_value(control_summary, primary_metric_key))
      efficiency_score = efficiency_score(summary, transformed, control_transformed)
      marginal_gain = marginal_gain(previous:, current_transformed: transformed)

      summary.merge(
        "primary_metric_value" => primary_value,
        "primary_metric_confidence_interval" => primary_metric_confidence_interval(summary),
        "transformed_primary_metric" => transformed,
        "efficiency_score" => efficiency_score,
        "efficiency_gain_vs_control" => efficiency_gain_vs_control(efficiency_score),
        "marginal_primary_gain" => marginal_gain,
        "scaling_exponent_vs_control" => exponent_for(summary:, transformed:, control_transformed: control_transformed),
        "signals" => build_signals(
          summary:,
          previous:,
          marginal_gain:,
          primary_value:,
          transformed:,
          control_transformed:
        )
      )
    end

    def primary_metric_key
      @primary_metric_key ||= begin
        metric = scaling_experiment.outcome_metrics.find { |candidate| candidate["primary"] == true }
        metric&.fetch("key", nil) || "success_rate"
      end
    end

    def primary_metric_objective
      @primary_metric_objective ||= begin
        metric = scaling_experiment.outcome_metrics.find { |candidate| candidate["key"] == primary_metric_key }
        metric&.fetch("objective", "maximize")
      end
    end

    def metric_value(summary, key)
      field = METRIC_KEY_TO_SUMMARY_FIELD.fetch(key.to_s, key.to_s)
      summary.fetch(field, nil)&.to_f
    end

    def transformed_primary_metric(value)
      return nil unless value

      case primary_metric_objective
      when "minimize"
        return nil unless value.positive?

        1.0 / value
      else
        value
      end
    end

    def efficiency_score(summary, transformed, control_transformed)
      return 0.0 unless transformed

      primary_gain = relative_change(transformed, control_transformed) || 0.0
      duration_gain = inverse_relative_change(
        metric_value(summary, :avg_duration_seconds),
        metric_value(control_summary, :avg_duration_seconds)
      ) || 0.0
      cost_gain = inverse_relative_change(
        metric_value(summary, :avg_cost_cents),
        metric_value(control_summary, :avg_cost_cents)
      ) || 0.0

      (primary_gain * 0.6 + duration_gain * 0.25 + cost_gain * 0.15).round(4)
    end

    def efficiency_gain_vs_control(score)
      return nil unless score

      score.round(4)
    end

    def relative_change(current, baseline)
      return nil unless current && baseline
      return 1.0 if baseline.zero? && current.positive?
      return 0.0 if baseline.zero?

      ((current - baseline) / baseline).round(4)
    end

    def inverse_relative_change(current, baseline)
      return nil unless current && baseline
      return nil if baseline.zero?

      ((baseline - current) / baseline).round(4)
    end

    def marginal_gain(previous:, current_transformed:)
      return nil unless previous && current_transformed

      previous_transformed = transformed_primary_metric(previous["primary_metric_value"])
      relative_change(current_transformed, previous_transformed)
    end

    def exponent_for(summary:, transformed:, control_transformed:)
      return nil unless transformed && control_transformed

      value = summary["assigned_value"].to_i
      control = scaling_experiment.control_value.to_i
      return nil if value <= 0 || control <= 0 || value == control
      return nil unless transformed.positive? && control_transformed.positive?

      (Math.log(transformed / control_transformed) / Math.log(value.to_f / control)).round(4)
    end

    def scaling_exponent
      scaling_exponent_confidence_interval["estimate"]
    end

    def scaling_exponent_confidence_interval
      @scaling_exponent_confidence_interval ||= ScalingExperiments::Statistics.log_log_slope_interval(
        points: viable_values.filter_map do |summary|
          transformed = summary["transformed_primary_metric"]&.to_f
          next unless transformed&.positive?

          { x: summary["assigned_value"].to_i, y: transformed }
        end,
        confidence_level:
      )
    end

    def diminishing_returns_at
      analyzed_values.find do |summary|
        summary["signals"].include?("diminishing_returns")
      end&.fetch("assigned_value", nil)
    end

    def build_signals(summary:, previous:, marginal_gain:, primary_value:, transformed:, control_transformed:)
      [].tap do |signals|
        signals << "diminishing_returns" if previous && marginal_gain && marginal_gain <= DIMINISHING_RETURNS_RATIO
        signals << "primary_metric_regression" if previous && regression?(primary_value:, previous:)
        signals << "efficiency_regression" if efficiency_score(summary, transformed, control_transformed) < 0
      end
    end

    def regression?(primary_value:, previous:)
      current = transformed_primary_metric(primary_value)
      prior = transformed_primary_metric(previous["primary_metric_value"])
      return false unless current && prior

      current < prior
    end

    def allocator_decision
      return unless recommended_summary

      value = recommended_summary["assigned_value"].to_i
      decision = {
        "dimension" => scaling_experiment.dimension,
        "recommended_value" => value,
        "sample_count" => recommended_summary["sample_count"],
        "confidence" => confidence_for(recommended_summary),
        "actionable" => actionable_recommendation?(recommended_summary),
        "reason" => recommendation_reason(recommended_summary),
        "efficiency_gain_vs_control" => recommended_summary["efficiency_gain_vs_control"],
        "scaling_exponent" => scaling_exponent,
        "diminishing_returns_at" => diminishing_returns_at,
        "scaling_exponent_confidence_interval" => scaling_exponent_confidence_interval
      }

      case scaling_experiment.dimension
      when "agent_count"
        decision.merge!(
          "requested_agent_count" => value,
          "max_batch_size" => value
        )
      when "parallelism"
        decision["max_batch_size"] = value
      when "iteration_count"
        decision.merge!(
          "requested_iteration_count" => value,
          "max_iterations" => value
        )
      when "max_iterations"
        decision["max_iterations"] = value
      end

      decision
    end

    def confidence_for(summary)
      return "high" if actionable_recommendation?(summary) && summary["sample_count"].to_i >= (configured_min_samples_per_value * 2)
      return "medium" if summary["sample_count"].to_i >= configured_min_samples_per_value
      return "medium" if summary["sample_count"].to_i >= MIN_SAMPLES

      "low"
    end

    def recommendation_reason(summary)
      if summary["signals"].include?("diminishing_returns")
        "highest_efficiency_at_threshold"
      else
        "highest_efficiency_before_threshold"
      end
    end

    def primary_metric_confidence_interval(summary)
      summary.fetch(confidence_interval_field_for(primary_metric_key), nil)
    end

    def confidence_interval_field_for(metric_key)
      "#{METRIC_KEY_TO_SUMMARY_FIELD.fetch(metric_key.to_s, metric_key.to_s)}_confidence_interval"
    end

    def configured_min_samples_per_value
      @configured_min_samples_per_value ||= begin
        value = scaling_experiment.min_samples_per_value.to_i
        [ value, MIN_SAMPLES ].max
      end
    end

    def actionable_recommendation?(summary)
      interval_width = ScalingExperiments::Statistics.relative_width(
        summary["primary_metric_confidence_interval"],
        baseline: summary["primary_metric_value"]
      )

      summary["sample_count"].to_i >= configured_min_samples_per_value &&
        summary["efficiency_gain_vs_control"].to_f >= MIN_EFFICIENCY_GAIN &&
        interval_width.present? &&
        interval_width <= MAX_ACTIONABLE_INTERVAL_WIDTH_RATIO
    end

    def sample_threshold_review
      {
        "configured_min_samples_per_value" => configured_min_samples_per_value,
        "analysis_min_samples_per_value" => MIN_SAMPLES,
        "rdr_target_min_samples_per_value" => RDR_TARGET_MIN_SAMPLES_PER_VALUE,
        "meets_rdr_target" => configured_min_samples_per_value >= RDR_TARGET_MIN_SAMPLES_PER_VALUE
      }
    end

    def statistical_rigor
      {
        "confidence_level" => confidence_level.round(2),
        "actionable_interval_width_ratio" => MAX_ACTIONABLE_INTERVAL_WIDTH_RATIO,
        "power_law_fit_method" => "log_log_linear_fit",
        "simplifications" => [
          "Uses descriptive confidence intervals rather than the full comparative regression suite proposed in the RDR.",
          "Treats configured experiment sample floors below 30 as intentional simplifications and flags them in reporting.",
          "Recommendation confidence is based on sample size and interval width, not a full hypothesis-testing pipeline."
        ]
      }
    end
  end
end
