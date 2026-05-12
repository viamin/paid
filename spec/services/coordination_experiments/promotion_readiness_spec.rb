# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationExperiments::PromotionReadiness do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:experiment) { create(:coordination_experiment, account: account, min_samples_per_variant: 2) }
  let!(:control) do
    create(:coordination_experiment_variant,
      coordination_experiment: experiment,
      policy_config: experiment.control_policy,
      is_control: true,
      sample_count: 2,
      avg_coordination_score: 0.6,
      total_coordination_score: 1.2)
  end
  let!(:variant) do
    create(:coordination_experiment_variant,
      coordination_experiment: experiment,
      policy_config: experiment.control_policy.merge("parallel_execution" => { "max_batch_size" => 1 }),
      sample_count: 2,
      avg_coordination_score: 0.8,
      total_coordination_score: 1.6)
  end

  before do
    [ true, true ].each_with_index do |success, index|
      create(:coordination_experiment_assignment,
        coordination_experiment: experiment,
        coordination_experiment_variant: control,
        project: project,
        issue: issue,
        workflow_id: "control-#{index}",
        outcome_status: "recorded",
        coordination_score: 0.6,
        outcome_metrics: {
          "success" => success,
          "completion_rate" => 1.0,
          "failed_task_rate" => 0.0,
          "dependency_failed_task_rate" => 0.0,
          "conflict_detected" => false,
          "manual_review_required" => false,
          "total_cost_cents" => 100,
          "total_duration_seconds" => 120,
          "avg_cost_per_task_cents" => 50,
          "avg_duration_per_task_seconds" => 60,
          "aggregated_pr_created" => false
        })
      create(:coordination_experiment_assignment,
        coordination_experiment: experiment,
        coordination_experiment_variant: variant,
        project: project,
        issue: issue,
        workflow_id: "variant-#{index}",
        outcome_status: "recorded",
        coordination_score: 0.8,
        outcome_metrics: {
          "success" => success,
          "completion_rate" => 1.0,
          "failed_task_rate" => 0.0,
          "dependency_failed_task_rate" => 0.0,
          "conflict_detected" => false,
          "manual_review_required" => false,
          "total_cost_cents" => 105,
          "total_duration_seconds" => 118,
          "avg_cost_per_task_cents" => 52.5,
          "avg_duration_per_task_seconds" => 59,
          "aggregated_pr_created" => true
        })
    end
  end

  def expect_ready_summary!(result)
    expect(result.candidate_summary).to include(
      avg_coordination_score: 0.8,
      completion_rate: 1.0,
      avg_cost_cents: 105.0,
      aggregated_pr_rate: 1.0
    )
  end

  def expect_regressed_readiness!(result)
    expect(result.status).to eq(:guardrail_failed)
    expect(result.reasons).to include(
      "completion_rate_regressed",
      "failed_task_rate_too_high",
      "dependency_failure_rate_too_high",
      "duration_increase_too_high"
    )
  end

  it "marks the evolved variant ready when quality improves within guardrails" do
    result = described_class.call(coordination_experiment: experiment)

    expect(result.status).to eq(:ready)
    expect(result.candidate).to eq(variant)
    expect(result.reasons).to eq([])
    expect_ready_summary!(result)
  end

  it "fails readiness when cost guardrails regress too far" do
    variant.coordination_experiment_assignments.recorded.update_all(
      outcome_metrics: {
        "success" => true,
        "completion_rate" => 1.0,
        "failed_task_rate" => 0.0,
        "dependency_failed_task_rate" => 0.0,
        "conflict_detected" => false,
        "manual_review_required" => false,
        "total_cost_cents" => 200,
        "total_duration_seconds" => 118,
        "avg_cost_per_task_cents" => 100,
        "avg_duration_per_task_seconds" => 59,
        "aggregated_pr_created" => false
      }
    )

    result = described_class.call(coordination_experiment: experiment)

    expect(result.status).to eq(:guardrail_failed)
    expect(result.reasons).to include("cost_increase_too_high")
  end

  it "fails readiness when the evolved policy is slower and less complete than control" do
    variant.update!(avg_coordination_score: 0.7, total_coordination_score: 1.4)
    variant.coordination_experiment_assignments.recorded.update_all(
      outcome_metrics: {
        "success" => true,
        "completion_rate" => 0.5,
        "failed_task_rate" => 0.5,
        "dependency_failed_task_rate" => 0.25,
        "conflict_detected" => false,
        "manual_review_required" => false,
        "total_cost_cents" => 105,
        "total_duration_seconds" => 200,
        "avg_cost_per_task_cents" => 52.5,
        "avg_duration_per_task_seconds" => 100,
        "aggregated_pr_created" => false
      }
    )

    result = described_class.call(coordination_experiment: experiment)

    expect_regressed_readiness!(result)
  end
end
