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

  def record_outcome!(task_count:, result:)
    described_class.call(
      assignment: assignment,
      task_count: task_count,
      parallel_execution: true,
      result: result
    )
  end

  def expect_recorded_metrics!
    expect(assignment.outcome_metrics).to include(
      "summary_version" => 1,
      "task_count" => 2,
      "parallel_execution" => true,
      "completion_rate" => 1.0,
      "failed_task_rate" => 0.0,
      "dependency_failed_task_rate" => 0.0,
      "successful_run_rate" => 0.5,
      "total_cost_cents" => 250,
      "total_duration_seconds" => 120,
      "avg_cost_per_task_cents" => 125.0,
      "avg_duration_per_task_seconds" => 60.0
    )
  end

  def penalized_result_payload
    {
      success: false,
      completed: 2,
      failed: 2,
      results: [
        { success: true, agent_run_id: run.id },
        { success: false, error: "dependencies_failed" },
        { success: false, error: "cancelled_by_policy" },
        { queued: true }
      ],
      conflicts: { has_conflicts: true, requires_manual_review: true }
    }
  end

  it "records workflow metrics and updates variant aggregates" do
    record_outcome!(task_count: 2, result: result_payload)

    assignment.reload
    variant.reload

    expect(assignment.outcome_status).to eq("recorded")
    expect_recorded_metrics!
    expect(assignment.coordination_score).to eq(1.0)
    expect(variant.sample_count).to eq(1)
    expect(variant.avg_coordination_score.to_f).to eq(1.0)
  end

  it "captures dependency and manual-review penalties in the recorded metrics" do
    record_outcome!(task_count: 4, result: penalized_result_payload)

    expect(assignment.reload.outcome_metrics).to include(
      "queued_task_rate" => 0.25,
      "dependency_failed_task_rate" => 0.25,
      "policy_cancelled_task_rate" => 0.25,
      "conflict_detected" => true,
      "manual_review_required" => true
    )
    expect(assignment.coordination_score.to_f).to be < 0.3
  end
end
