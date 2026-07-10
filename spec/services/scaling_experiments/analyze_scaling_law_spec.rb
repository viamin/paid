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

    expect_recommended_agent_count_analysis(result)
  end

  it "maps validated metric keys to summary field names (total_cost_cents -> avg_cost_cents)" do
    allow(experiment).to receive(:outcome_metrics).and_return(
      [
        { "key" => "total_cost_cents", "primary" => true, "objective" => "minimize" },
        { "key" => "duration_seconds", "primary" => false, "objective" => "minimize" }
      ]
    )

    result = analyze(
      build_summary(1, sample_count: 3, success_rate: 0.90, duration: 120, cost: 400),
      build_summary(2, sample_count: 3, success_rate: 0.85, duration: 100, cost: 200)
    )

    # The primary metric value should be the avg_cost_cents from the summary, not nil
    values = result.fetch("values")
    expect(values.first["primary_metric_value"]).to eq(400.0)
    expect(values.last["primary_metric_value"]).to eq(200.0)
    expect(result["scaling_exponent"]).not_to be_nil
  end

  it "ranks on transformed metric so minimize objectives pick lowest cost as leading value" do
    allow(experiment).to receive(:outcome_metrics).and_return(
      [
        { "key" => "total_cost_cents", "primary" => true, "objective" => "minimize" },
        { "key" => "success_rate", "primary" => false, "objective" => "maximize" },
        { "key" => "duration_seconds", "primary" => false, "objective" => "minimize" }
      ]
    )

    result = analyze(
      build_summary(1, sample_count: 3, success_rate: 0.90, duration: 120, cost: 500),
      build_summary(2, sample_count: 3, success_rate: 0.85, duration: 150, cost: 200),
      build_summary(4, sample_count: 3, success_rate: 0.80, duration: 200, cost: 100)
    )

    expect(result["leading_value"]).to eq(4)
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

  it "emits regression signals when the primary metric and efficiency fall below the prior value" do
    result = analyze(
      build_summary(1, sample_count: 3, success_rate: 0.80, duration: 200, cost: 100),
      build_summary(2, sample_count: 3, success_rate: 0.95, duration: 150, cost: 120),
      build_summary(4, sample_count: 3, success_rate: 0.70, duration: 260, cost: 180)
    )

    expect(result.fetch("values")).to include(
      hash_including(
        "assigned_value" => 4,
        "signals" => include("primary_metric_regression", "efficiency_regression")
      )
    )
  end

  def analyze(*value_summaries)
    described_class.call(
      scaling_experiment: experiment,
      value_summaries: value_summaries
    ).to_h
  end

  def expect_recommended_agent_count_analysis(result)
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
    expect(result.dig("allocator_decision", "max_batch_size")).to eq(2)
    expect(result.dig("allocator_decision", "efficiency_gain_vs_control")).to be >= 0.10
    expect(result.dig("allocator_decision", "actionable")).to be(true)
    expect(result.dig("scaling_exponent_confidence_interval", "estimate")).to eq(result["scaling_exponent"])
    expect(result.dig("sample_threshold_review", "rdr_target_min_samples_per_value")).to eq(30)
    expect(result.fetch("values")).to include(
      hash_including("assigned_value" => 4, "signals" => include("diminishing_returns"))
    )
  end

  def build_summary(assigned_value, sample_count:, success_rate:, duration:, cost:)
    {
      "assigned_value" => assigned_value,
      "sample_count" => sample_count,
      "success_rate" => success_rate,
      "success_rate_confidence_interval" => {
        "mean" => success_rate,
        "lower_bound" => [ success_rate - 0.05, 0.0 ].max.round(4),
        "upper_bound" => [ success_rate + 0.05, 1.0 ].min.round(4),
        "margin_of_error" => 0.05,
        "sample_count" => sample_count,
        "confidence_level" => 0.95
      },
      "avg_duration_seconds" => duration,
      "avg_duration_seconds_confidence_interval" => {
        "mean" => duration.to_f,
        "lower_bound" => (duration - 10).to_f,
        "upper_bound" => (duration + 10).to_f,
        "margin_of_error" => 10.0,
        "sample_count" => sample_count,
        "confidence_level" => 0.95
      },
      "avg_cost_cents" => cost,
      "avg_cost_cents_confidence_interval" => {
        "mean" => cost.to_f,
        "lower_bound" => (cost - 10).to_f,
        "upper_bound" => (cost + 10).to_f,
        "margin_of_error" => 10.0,
        "sample_count" => sample_count,
        "confidence_level" => 0.95
      }
    }
  end
end
