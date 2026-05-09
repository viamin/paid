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
      control = summaries.find { |summary| summary["assigned_value"] == scaling_experiment.control_value }
      leader = summaries.max_by do |summary|
        [
          summary["success_rate"],
          summary["sample_count"],
          -summary["avg_duration_seconds"]
        ]
      end

      {
        "status" => scaling_experiment.sufficient_samples? ? "ready_for_analysis" : "collecting",
        "dimension" => scaling_experiment.dimension,
        "control_value" => scaling_experiment.control_value,
        "sample_count" => summaries.sum { |summary| summary["sample_count"] },
        "values" => summaries,
        "leading_value" => leader&.fetch("assigned_value", nil),
        "improvement_over_control" => improvement_over_control(control:, leader:)
      }.compact
    end

    private

    attr_reader :scaling_experiment

    def value_summaries
      assignments_by_value = scaling_experiment.scaling_experiment_assignments
        .recorded
        .includes(:scaling_observation)
        .group_by(&:assigned_value)

      scaling_experiment.values_tested.map(&:to_i).uniq.sort.map do |value|
        assignments = assignments_by_value.fetch(value, [])
        observations = assignments.filter_map(&:scaling_observation)
        {
          "assigned_value" => value,
          "sample_count" => observations.size,
          "success_rate" => rate(observations, &:success),
          "avg_duration_seconds" => average(observations, &:duration_seconds),
          "avg_cost_cents" => average(observations, &:total_cost_cents),
          "avg_parallelism_observed" => average(observations, &:parallelism_observed),
          "avg_agent_count_launched" => average(observations, &:agent_count_launched),
          "status_tally" => observations.map(&:status).tally
        }
      end
    end

    def improvement_over_control(control:, leader:)
      return unless control && leader

      {
        "success_rate_delta" => (leader["success_rate"] - control["success_rate"]).round(4),
        "duration_seconds_delta" => (leader["avg_duration_seconds"] - control["avg_duration_seconds"]).round(4),
        "cost_cents_delta" => (leader["avg_cost_cents"] - control["avg_cost_cents"]).round(4)
      }
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
