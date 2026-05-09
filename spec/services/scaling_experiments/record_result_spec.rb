# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingExperiments::RecordResult do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:experiment) do
    create(:scaling_experiment,
      project: project,
      values_tested: [ 1, 2 ],
      min_samples_per_value: 2,
      cached_summary: {})
  end

  def create_observation!(workflow_id:, assigned_value:, success:, cost_cents:, duration_seconds:, quality_scores: [])
    observation = create(:scaling_observation,
      project: project,
      issue: issue,
      workflow_id: workflow_id,
      success: success,
      status: success ? "completed" : "partial_failure",
      agent_count_planned: assigned_value,
      agent_count_launched: assigned_value,
      parallelism_observed: assigned_value,
      total_cost_cents: cost_cents,
      duration_seconds: duration_seconds)

    assignment = create(:scaling_experiment_assignment,
      scaling_experiment: experiment,
      project: project,
      issue: issue,
      workflow_id: workflow_id,
      assigned_value: assigned_value,
      execution_plan: {
        "max_batch_size" => assigned_value,
        "requested_agent_count" => assigned_value,
        "cohort_label" => experiment.cohort_label(task_count: assigned_value, assigned_value: assigned_value)
      })

    quality_scores.each do |score|
      run = create(:agent_run, :completed, project: project, issue: issue, parent_workflow_id: workflow_id)
      create(:quality_metric, agent_run: run, metric_type: "automated", composite_score: score)
    end

    described_class.call(assignment: assignment, scaling_observation: observation)
  end

  def expect_recorded_summary(assignment)
    expect(assignment.outcome_summary).to include(
      "cohort_label" => "agent_count-2__tasks-2-3",
      "status" => "completed",
      "success" => true,
      "total_cost_cents" => 350
    )
  end

  it "captures a normalized outcome snapshot and refreshes the experiment summary" do
    result = create_observation!(
      workflow_id: "wf-1",
      assigned_value: 2,
      success: true,
      cost_cents: 350,
      duration_seconds: 180,
      quality_scores: [ 0.7, 0.9 ]
    )

    assignment = result.assignment.reload
    experiment.reload

    expect_recorded_assignment_summary(assignment)
    expect_cached_experiment_summary(experiment)
  end

  it "completes the experiment once every value reaches the minimum sample count" do
    create_observation!(workflow_id: "wf-1", assigned_value: 1, success: true, cost_cents: 100, duration_seconds: 100)
    create_observation!(workflow_id: "wf-2", assigned_value: 1, success: true, cost_cents: 120, duration_seconds: 120)
    create_observation!(workflow_id: "wf-3", assigned_value: 2, success: false, cost_cents: 200, duration_seconds: 200)
    create_observation!(workflow_id: "wf-4", assigned_value: 2, success: true, cost_cents: 220, duration_seconds: 150)

    experiment.reload

    expect(experiment.status).to eq("completed")
    expect(experiment.cached_summary).to include(
      "status" => "ready_for_analysis",
      "leading_value" => 1,
      "parallelism_analysis" => hash_including(
        "status" => "ready",
        "recommended_agent_count" => 1
      ),
      "allocator_decision" => hash_including(
        "requested_agent_count" => 1,
        "max_batch_size" => 1
      )
    )
  end

  def expect_assignment_snapshot(assignment)
    expect(assignment.outcome_status).to eq("recorded")
    expect_recorded_summary(assignment)
  end

  def expect_collecting_summary(experiment)
    expect(experiment.cached_summary).to include(
      "status" => "collecting",
      "primary_metric" => "success_rate",
      "sample_count" => 1,
      "values" => array_including(hash_including("assigned_value" => 2, "sample_count" => 1)),
      "parallelism_analysis" => hash_including("status" => "insufficient_data")
    )
    expect(experiment.cached_summary).not_to have_key("allocator_decision")
  end

  def expect_recorded_assignment_summary(assignment)
    expect(assignment.outcome_status).to eq("recorded")
    expect(assignment.outcome_summary).to include(
      "status" => "completed",
      "success" => true,
      "total_cost_cents" => 350,
      "quality_metric_sample_count" => 2,
      "avg_quality_score" => 0.8
    )
  end

  def expect_cached_experiment_summary(experiment)
    expect(experiment.cached_summary).to include(
      "status" => "collecting",
      "sample_count" => 1,
      "values" => array_including(hash_including("assigned_value" => 2, "sample_count" => 1, "avg_quality_score" => 0.8))
    )
  end
end
