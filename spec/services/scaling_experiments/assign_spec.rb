# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingExperiments::Assign do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:experiment) { create(:scaling_experiment, project: project, values_tested: [ 1, 2, 4 ]) }

  def configure_iteration_experiment!
    experiment.update!(
      dimension: "max_iterations",
      values_tested: [ 1, 3, 5 ],
      control_value: 1,
      independent_variables: [
        {
          "key" => "max_iterations",
          "role" => "primary",
          "values" => [ 1, 3, 5 ],
          "control_value" => 1,
          "source" => "execution_plan"
        },
        {
          "key" => "task_count",
          "role" => "stratification",
          "source" => "scaling_observations.task_count"
        }
      ]
    )
  end

  def build_iteration_assignment
    iteration_experiment = create(:scaling_experiment,
      project: project,
      dimension: "iteration_count",
      values_tested: [ 1, 2, 4 ])

    described_class.call(
      scaling_experiment: iteration_experiment,
      project: project,
      issue: issue,
      workflow_id: "wf-iterations",
      task_count: 2
    )
  end

  def expect_iteration_execution_plan(assignment)
    expect(assignment.execution_plan).to include(
      "dimension" => "iteration_count",
      "dimension_value" => assignment.assigned_value,
      "requested_iteration_count" => assignment.assigned_value,
      "application_mode" => "task_prompt_budget"
    )
    expect(assignment.execution_plan["eligible_values"]).to eq([ 1, 2, 4 ])
    expect(assignment.execution_plan["prompt_suffix"]).to include("Iteration budget")
    expect(assignment.execution_plan["result_capture"]).to include(
      "store_assignment_outcome_summary" => true,
      "observation_scope" => "workflow"
    )
    expect(assignment.execution_plan["result_capture"]["child_run_metrics"])
      .to include("quality_score", "iterations", "duration_seconds", "cost_cents")
  end

  def expect_agent_count_assignment_plan(assignment)
    expect(assignment.execution_plan).to include(
      "plan_version" => 1,
      "dimension" => "agent_count",
      "dimension_value" => assignment.assigned_value,
      "dimension_role" => assignment.assigned_value == 1 ? "control" : "treatment",
      "task_count" => 4,
      "task_bucket" => "tasks-4-6",
      "application_target" => "parallel_execution.max_batch_size",
      "parallel_execution_required" => true
    )
    expect(assignment.execution_plan["cohort_label"]).to eq("agent_count-#{assignment.assigned_value}__tasks-4-6")
    expect(assignment.execution_plan["control"]).to include(
      "dimension_value" => 1,
      "cohort_label" => "agent_count-1__tasks-4-6",
      "comparison_method" => "within_task_count_bucket"
    )
    expect(assignment.execution_plan["fairness_guardrails"]).to include(
      "fairness_conditions" => array_including("same_project"),
      "guardrails" => array_including("respect_dependency_order")
    )
    expect(assignment.execution_plan["safety_limits"]).to include(
      "task_count_cap" => 4,
      "eligible_value_count" => 3
    )
  end

  it "creates a workflow-scoped assignment with a safe execution plan" do
    assignment = described_class.call(
      scaling_experiment: experiment,
      project: project,
      issue: issue,
      workflow_id: "wf-123",
      task_count: 4
    )

    expect(assignment.project).to eq(project)
    expect(assignment.issue).to eq(issue)
    expect(assignment.workflow_id).to eq("wf-123")
    expect_agent_count_assignment_plan(assignment)
  end

  it "reuses the existing assignment for the same workflow" do
    first = described_class.call(
      scaling_experiment: experiment,
      project: project,
      workflow_id: "wf-123",
      task_count: 4
    )
    second = described_class.call(
      scaling_experiment: experiment,
      project: project,
      workflow_id: "wf-123",
      task_count: 4
    )

    expect(second.id).to eq(first.id)
  end

  it "balances across only the values that are eligible for the task count" do
    assignments = 6.times.map do |index|
      described_class.call(
        scaling_experiment: experiment,
        project: project,
        workflow_id: "wf-#{index}",
        task_count: 2
      )
    end

    counts = assignments.map(&:assigned_value).tally

    expect(counts.keys).to contain_exactly(1, 2)
    counts.each_value { |count| expect(count).to be_between(2, 4) }
  end

  it "skips assignments when the task count does not satisfy the context filter" do
    experiment.update!(context_filter: { "min_task_count" => 5 })

    assignment = described_class.call(
      scaling_experiment: experiment,
      project: project,
      workflow_id: "wf-123",
      task_count: 4
    )

    expect(assignment).to be_nil
  end

  it "builds an iteration-budget execution plan for iteration_count experiments" do
    expect_iteration_execution_plan(build_iteration_assignment)
  end

  it "builds a dimension-specific execution plan for max_iterations experiments" do
    configure_iteration_experiment!

    assignment = described_class.call(
      scaling_experiment: experiment,
      project: project,
      workflow_id: "wf-iteration",
      task_count: 4
    )

    expect(assignment.execution_plan).to include(
      "dimension" => "max_iterations",
      "dimension_value" => assignment.assigned_value,
      "max_iterations_per_agent" => assignment.assigned_value
    )
  end
end
