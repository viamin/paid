# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationExperiments::RecordOutcome do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:experiment) { create(:coordination_experiment, account: account, status: "running") }
  let(:variant) { create(:coordination_experiment_variant, coordination_experiment: experiment) }
  let(:assignment) do
    create(:coordination_experiment_assignment,
      coordination_experiment: experiment,
      coordination_experiment_variant: variant,
      project: project,
      issue: issue)
  end
  let!(:run) do
    create(:agent_run,
      :completed,
      project: project,
      issue: issue,
      cost_cents: 250,
      duration_seconds: 120,
      iterations: 2)
  end
  let(:result_payload) do
    {
      success: true,
      completed: 2,
      failed: 0,
      results: [ { success: true, agent_run_id: run.id }, { success: true } ],
      conflicts: { has_conflicts: false, requires_manual_review: false }
    }
  end

  it "records workflow metrics and updates variant aggregates" do
    described_class.call(
      assignment: assignment,
      task_count: 2,
      parallel_execution: true,
      result: result_payload
    )

    assignment.reload
    variant.reload

    expect(assignment.outcome_status).to eq("recorded")
    expect(assignment.outcome_metrics).to include(
      "task_count" => 2,
      "parallel_execution" => true,
      "total_cost_cents" => 250,
      "total_duration_seconds" => 120
    )
    expect(assignment.coordination_score).to eq(1.0)
    expect(variant.sample_count).to eq(1)
    expect(variant.avg_coordination_score.to_f).to eq(1.0)
  end
end
