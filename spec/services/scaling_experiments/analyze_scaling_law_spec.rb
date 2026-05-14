# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingExperiments::AnalyzeScalingLaw, :no_db do
  let(:dimension) { "agent_count" }
  let(:values_tested) { [ 1, 2, 4 ] }
  let(:control_value) { 1 }
  let(:experiment) do
    Struct.new(:dimension, :values_tested, :control_value, :outcome_metrics, keyword_init: true).new(
      dimension: dimension,
      values_tested: values_tested,
      control_value: control_value,
      outcome_metrics: outcome_metrics
    )
  end
  let(:outcome_metrics) do
    [
      { "key" => "success_rate", "primary" => true, "objective" => "maximize" },
      { "key" => "duration_seconds", "primary" => false, "objective" => "minimize" },
      { "key" => "total_cost_cents", "primary" => false, "objective" => "minimize" }
    ]
  end

  it "estimates a scaling exponent and recommends the most efficient value before diminishing returns" do
    result = analyze(
      build_summary(1, sample_count: 3, success_rate: 0.50, duration: 300, cost: 100),
      build_summary(2, sample_count: 3, success_rate: 0.90, duration: 180, cost: 160),
      build_summary(4, sample_count: 3, success_rate: 0.95, duration: 170, cost: 360)
    )

    expect(result).to include(
      "status" => "ready",
      "dimension" => "agent_count",
      "control_value" => 1,
      "recommended_value" => 2,
      "leading_value" => 4,
      "diminishing_returns_at" => 4
    )
    expect(result["scaling_exponent"]).to be > 0
    expect(result.dig("allocator_decision", "requested_agent_count")).to eq(2)
    expect(result.dig("allocator_decision", "efficiency_gain_vs_control")).to be >= 0.10
    expect(result.fetch("values")).to include(
      hash_including("assigned_value" => 4, "signals" => include("diminishing_returns"))
    )
  end

  it "emits iteration allocation guidance for iteration-count experiments" do
    allow(experiment).to receive(:dimension).and_return("iteration_count")

    result = analyze(
      build_summary(1, sample_count: 3, success_rate: 0.55, duration: 260, cost: 110),
      build_summary(2, sample_count: 3, success_rate: 0.82, duration: 180, cost: 135),
      build_summary(4, sample_count: 3, success_rate: 0.84, duration: 178, cost: 220)
    )

    expect(result.dig("allocator_decision", "requested_iteration_count")).to eq(2)
    expect(result.dig("allocator_decision", "max_iterations")).to eq(2)
  end

  def analyze(*value_summaries)
    described_class.call(
      scaling_experiment: experiment,
      value_summaries: value_summaries
    ).to_h
  end

  def build_summary(assigned_value, sample_count:, success_rate:, duration:, cost:)
    {
      "assigned_value" => assigned_value,
      "sample_count" => sample_count,
      "success_rate" => success_rate,
      "avg_duration_seconds" => duration,
      "avg_cost_cents" => cost
    }
  end
end
