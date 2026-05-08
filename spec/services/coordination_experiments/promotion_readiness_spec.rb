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
          "conflict_detected" => false,
          "manual_review_required" => false,
          "total_cost_cents" => 100
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
          "conflict_detected" => false,
          "manual_review_required" => false,
          "total_cost_cents" => 105
        })
    end
  end

  it "marks the evolved variant ready when quality improves within guardrails" do
    result = described_class.call(coordination_experiment: experiment)

    expect(result.status).to eq(:ready)
    expect(result.candidate).to eq(variant)
    expect(result.reasons).to eq([])
  end

  it "fails readiness when cost guardrails regress too far" do
    variant.coordination_experiment_assignments.recorded.update_all(
      outcome_metrics: {
        "success" => true,
        "conflict_detected" => false,
        "manual_review_required" => false,
        "total_cost_cents" => 200
      }
    )

    result = described_class.call(coordination_experiment: experiment)

    expect(result.status).to eq(:guardrail_failed)
    expect(result.reasons).to include("cost_increase_too_high")
  end
end
