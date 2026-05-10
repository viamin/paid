# frozen_string_literal: true

module ScalingExperiments
  class SummarizeResults
    def self.call(...)
      new(...).call
    end

    def initialize(scaling_experiment:)
      @scaling_experiment = scaling_experiment
    end

    def call
      summaries = value_summaries
      analysis = parallelism_analysis
      control = summaries.find { |summary| summary["assigned_value"] == scaling_experiment.control_value }
      leader = summaries.max_by { |summary| leader_sort_key(summary) }

      {
        "status" => scaling_experiment.sufficient_samples? ? "ready_for_analysis" : "collecting",
        "dimension" => scaling_experiment.dimension,
        "control_value" => scaling_experiment.control_value,
        "primary_metric" => primary_metric,
        "cohort_strategy" => scaling_experiment.cohort_settings.slice("assignment_strategy", "cadence", "label_template"),
        "sample_count" => summaries.sum { |summary| summary["sample_count"] },
        "values" => summaries,
        "parallelism_analysis" => analysis,
        "allocator_decision" => analysis["allocator_decision"],
        "leading_value" => leader&.fetch("assigned_value", nil),
        "improvement_over_control" => improvement_over_control(control:, leader:)
      }.compact
    end

    private

    attr_reader :scaling_experiment

    def primary_metric
      metric = scaling_experiment.outcome_metrics.find { |candidate| candidate["primary"] == true }
      metric&.fetch("key", nil)
    end

    def value_summaries
      assignments_by_value = loaded_assignments.group_by(&:assigned_value)

      scaling_experiment.values_tested.map(&:to_i).uniq.sort.map do |value|
        assignments = assignments_by_value.fetch(value, [])
        observations = assignments.filter_map(&:scaling_observation)
        {
          "assigned_value" => value,
          "sample_count" => observations.size,
          "success_rate" => rate(observations, &:success),
          "avg_total_iterations" => average(observations, &:total_iterations),
          "avg_max_iterations" => average(observations, &:max_iterations),
          "avg_duration_seconds" => average(observations, &:duration_seconds),
          "avg_cost_cents" => average(observations, &:total_cost_cents),
          "avg_quality_score" => average_quality_score(assignments),
          "quality_metric_sample_count" => quality_metric_sample_count(assignments),
          "avg_parallelism_observed" => average(observations, &:parallelism_observed),
          "avg_agent_count_launched" => average(observations, &:agent_count_launched),
          "status_tally" => observations.map(&:status).tally
        }
      end
    end

    def loaded_assignments
      @loaded_assignments ||= scaling_experiment.scaling_experiment_assignments
        .recorded
        .includes(:scaling_observation)
        .to_a
    end

    def recorded_observations
      @recorded_observations ||= loaded_assignments.filter_map(&:scaling_observation)
    end

    def parallelism_analysis
      ScalingObservations::AnalyzeParallelism.call(observations: recorded_observations).to_h
    end

    def improvement_over_control(control:, leader:)
      return unless control && leader

      {
        "quality_score_delta" => delta(leader["avg_quality_score"], control["avg_quality_score"]),
        "success_rate_delta" => delta(leader["success_rate"], control["success_rate"]),
        "duration_seconds_delta" => delta(leader["avg_duration_seconds"], control["avg_duration_seconds"]),
        "cost_cents_delta" => delta(leader["avg_cost_cents"], control["avg_cost_cents"])
      }
    end

    def leader_sort_key(summary)
      [
        summary["quality_metric_sample_count"].to_i.positive? ? 1 : 0,
        summary["avg_quality_score"].to_f,
        summary["success_rate"],
        summary["sample_count"],
        -summary["avg_duration_seconds"],
        -summary["avg_cost_cents"]
      ]
    end

    def average_quality_score(assignments)
      quality_scores = assignments.filter_map { |assignment| assignment.outcome_summary["avg_quality_score"]&.to_f }
      return nil if quality_scores.empty?

      (quality_scores.sum / quality_scores.size).round(4)
    end

    def quality_metric_sample_count(assignments)
      assignments.sum { |assignment| assignment.outcome_summary["quality_metric_sample_count"].to_i }
    end

    def delta(value, control)
      return unless value && control

      (value - control).round(4)
    end

    def rate(observations)
      return 0.0 if observations.empty?

      (observations.count { |observation| yield(observation) }.to_f / observations.size).round(4)
    end

    def average(observations)
      return 0.0 if observations.empty?

      (observations.sum { |observation| yield(observation).to_f } / observations.size).round(4)
    end
  end
end
