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

  def create_observation!(workflow_id:, assigned_value:, success:, cost_cents:, duration_seconds:, quality_scores: [],
    total_iterations: assigned_value, max_iterations: assigned_value, parallelism_planned: assigned_value, batch_count: 1)
    observation = create(:scaling_observation,
      project: project,
      issue: issue,
      workflow_id: workflow_id,
      success: success,
      status: success ? "completed" : "partial_failure",
      agent_count_planned: assigned_value,
      agent_count_launched: assigned_value,
      total_iterations: total_iterations,
      max_iterations: max_iterations,
      parallelism_planned: parallelism_planned,
      parallelism_observed: assigned_value,
      batch_count: batch_count,
      total_cost_cents: cost_cents,
      duration_seconds: duration_seconds)

    assignment = create(:scaling_experiment_assignment,
      scaling_experiment: experiment,
      project: project,
      issue: issue,
      workflow_id: workflow_id,
      assigned_value: assigned_value,
      execution_plan: {
        "dimension" => "agent_count",
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
      quality_scores: [ 0.7, 0.9 ],
      total_iterations: 5,
      max_iterations: 3,
      parallelism_planned: 2,
      batch_count: 2
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
      "dimension" => "agent_count",
      "assigned_value" => 2,
      "status" => "completed",
      "success" => true,
      "total_iterations" => 5,
      "max_iterations" => 3,
      "parallelism_planned" => 2,
      "batch_count" => 2,
      "total_cost_cents" => 350,
      "child_run_count" => 2,
      "quality_metric_sample_count" => 2,
      "avg_quality_score" => 0.8
    )
    expect(assignment.outcome_summary["child_run_metrics"]).to contain_exactly(
      hash_including(
        "status" => "completed",
        "iterations" => 0,
        "duration_seconds" => 600,
        "quality_score" => 0.7
      ),
      hash_including(
        "status" => "completed",
        "iterations" => 0,
        "duration_seconds" => 600,
        "quality_score" => 0.9
      )
    )
  end

  def expect_cached_experiment_summary(experiment)
    expect(experiment.cached_summary).to include(
      "status" => "collecting",
      "sample_count" => 1,
      "values" => array_including(hash_including(
        "assigned_value" => 2,
        "sample_count" => 1,
        "avg_quality_score" => 0.8,
        "avg_total_iterations" => 4.0,
        "avg_max_iterations" => 2.0
      ))
    )
  end

  def build_iteration_experiment_result
    iteration_experiment = create(:scaling_experiment,
      project: project,
      dimension: "iteration_count",
      values_tested: [ 1, 3 ],
      control_value: 1)
    observation = create(:scaling_observation,
      project: project,
      issue: issue,
      workflow_id: "wf-iterations",
      success: true,
      status: "completed",
      total_iterations: 4,
      max_iterations: 3,
      total_cost_cents: 280,
      duration_seconds: 240)
    assignment = create(:scaling_experiment_assignment,
      scaling_experiment: iteration_experiment,
      project: project,
      issue: issue,
      workflow_id: "wf-iterations",
      assigned_value: 3,
      execution_plan: {
        "dimension" => "iteration_count",
        "requested_iteration_count" => 3,
        "application_mode" => "task_prompt_budget",
        "cohort_label" => "iteration_count-3__tasks-2-3"
      })

    first_run = create(:agent_run, :completed, project: project, issue: issue,
      parent_workflow_id: "wf-iterations", iterations: 3, duration_seconds: 180, cost_cents: 140)
    second_run = create(:agent_run, :completed, project: project, issue: issue,
      parent_workflow_id: "wf-iterations", iterations: 1, duration_seconds: 60, cost_cents: 140)
    create(:quality_metric, agent_run: first_run, metric_type: "automated", composite_score: 0.9)
    create(:quality_metric, agent_run: second_run, metric_type: "automated", composite_score: 0.7)

    {
      iteration_experiment: iteration_experiment,
      first_run: first_run,
      second_run: second_run,
      result: described_class.call(assignment: assignment, scaling_observation: observation)
    }
  end

  def expect_iteration_assignment_outcome(result, first_run:, second_run:)
    expect(result.assignment.reload.outcome_summary).to include(
      "dimension" => "iteration_count",
      "assigned_value" => 3,
      "requested_iteration_count" => 3,
      "application_mode" => "task_prompt_budget",
      "total_iterations" => 4,
      "max_iterations" => 3,
      "duration_seconds" => 240,
      "total_cost_cents" => 280,
      "avg_quality_score" => 0.8
    )
    expect(result.assignment.outcome_summary["child_run_metrics"]).to contain_exactly(
      hash_including(
        "agent_run_id" => first_run.id,
        "iterations" => 3,
        "duration_seconds" => 180,
        "cost_cents" => 140,
        "quality_score" => 0.9
      ),
      hash_including(
        "agent_run_id" => second_run.id,
        "iterations" => 1,
        "duration_seconds" => 60,
        "cost_cents" => 140,
        "quality_score" => 0.7
      )
    )
  end

  def expect_iteration_experiment_summary(iteration_experiment)
    expect(iteration_experiment.reload.cached_summary["values"]).to include(
      hash_including(
        "assigned_value" => 3,
        "avg_total_iterations" => 4.0,
        "avg_max_iterations" => 3.0,
        "avg_duration_seconds" => 240.0,
        "avg_cost_cents" => 280.0,
        "avg_quality_score" => 0.8
      )
    )
  end

  it "stores iteration-count experiment outputs for downstream analysis" do
    payload = build_iteration_experiment_result

    expect_iteration_assignment_outcome(payload[:result], first_run: payload[:first_run], second_run: payload[:second_run])
    expect_iteration_experiment_summary(payload[:iteration_experiment])
  end
end
