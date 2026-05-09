# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingObservations::Record do
  describe ".call" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }
    let(:workflow_id) { "feature-wf-123" }

    it "persists scaling metrics for a completed parallel orchestration" do
      child_runs = create_parallel_child_runs

      expect_completed_parallel_observation(
        build_completed_parallel_observation(child_runs: child_runs),
        project: project,
        issue: issue,
        workflow_id: workflow_id,
        child_run_ids: child_runs.map(&:id)
      )
    end

    it "persists a skipped observation for single-task orchestration" do
      observation = described_class.call(
        project_id: project.id,
        issue_id: issue.id,
        workflow_id: workflow_id,
        workflow_name: "Workflows::FeatureOrchestrationWorkflow",
        tasks: [ { index: 0, parallel_group: 0, dependencies: [] } ]
      )

      expect(observation).to have_attributes(
        status: "skipped",
        success: true,
        parallel_execution: false,
        task_count: 1,
        agent_count_planned: 1,
        agent_count_launched: 0,
        agent_count_succeeded: 0,
        agent_count_failed: 0,
        agent_count_blocked: 0,
        parallelism_planned: 1,
        parallelism_observed: 0
      )
    end

    it "preserves no_capacity when capacity is exhausted after some tasks launch" do
      expect(build_no_capacity_observation).to have_attributes(
        status: "no_capacity",
        success: false,
        agent_count_launched: 1,
        agent_count_failed: 0,
        agent_count_blocked: 2
      )
    end

    it "preserves deadline_exceeded when the workflow times out mid-run" do
      expect(build_deadline_exceeded_observation).to have_attributes(
        status: "deadline_exceeded",
        success: false,
        agent_count_launched: 1,
        agent_count_failed: 0,
        agent_count_blocked: 1
      )
    end
  end

  def create_parallel_child_runs
    [
      create(:agent_run, :completed, project: project, issue: issue,
        parent_workflow_id: workflow_id, iterations: 3, cost_cents: 120, tokens_input: 400, tokens_output: 150),
      create(:agent_run, :completed, project: project, issue: issue,
        parent_workflow_id: workflow_id, iterations: 1, cost_cents: 80, tokens_input: 300, tokens_output: 125),
      create(:agent_run, :failed, project: project, issue: issue,
        parent_workflow_id: workflow_id, iterations: 2, cost_cents: 60, tokens_input: 200, tokens_output: 50)
    ]
  end

  def build_completed_parallel_observation(child_runs:)
    travel_to(Time.zone.parse("2026-05-08 22:00:10 UTC")) do
      described_class.call(
        project_id: project.id,
        issue_id: issue.id,
        workflow_id: workflow_id,
        workflow_name: "Workflows::FeatureOrchestrationWorkflow",
        started_at: Time.zone.parse("2026-05-08 22:00:00 UTC"),
        tasks: [
          { index: 0, parallel_group: 0, dependencies: [] },
          { index: 1, parallel_group: 0, dependencies: [] },
          { index: 2, parallel_group: 1, dependencies: [ 0 ] }
        ],
        parallel_result: completed_parallel_result(child_runs),
        metadata: {
          created_issues: [ { issue_id: 10 }, { issue_id: 11 }, { issue_id: 12 } ]
        }
      )
    end
  end

  def completed_parallel_result(child_runs)
    {
      success: false,
      total: 3,
      completed: 2,
      failed: 1,
      results: [
        { issue_id: 10, task_index: 0, success: true, agent_run_id: child_runs[0].id },
        { issue_id: 11, task_index: 1, success: true, agent_run_id: child_runs[1].id },
        { issue_id: 12, task_index: 2, success: false, agent_run_id: child_runs[2].id, error: "Agent execution failed" }
      ],
      execution_summary: {
        batch_count: 2,
        batch_sizes: [ 2, 1 ],
        max_parallelism_observed: 2
      }
    }
  end

  def build_no_capacity_observation
    described_class.call(
      project_id: project.id,
      issue_id: issue.id,
      workflow_id: workflow_id,
      workflow_name: "Workflows::FeatureOrchestrationWorkflow",
      tasks: [
        { index: 0, parallel_group: 0, dependencies: [] },
        { index: 1, parallel_group: 0, dependencies: [] },
        { index: 2, parallel_group: 1, dependencies: [ 1 ] }
      ],
      parallel_result: {
        success: false,
        total: 3,
        completed: 1,
        failed: 0,
        results: [
          { issue_id: 10, task_index: 0, success: true, agent_run_id: 101 },
          { issue_id: 11, task_index: 1, success: false, error: "no_capacity", queued: true },
          { issue_id: 12, task_index: 2, success: false, error: "dependencies_failed", blocked_by: [ 1 ] }
        ]
      }
    )
  end

  def build_deadline_exceeded_observation
    described_class.call(
      project_id: project.id,
      issue_id: issue.id,
      workflow_id: workflow_id,
      workflow_name: "Workflows::FeatureOrchestrationWorkflow",
      tasks: [
        { index: 0, parallel_group: 0, dependencies: [] },
        { index: 1, parallel_group: 1, dependencies: [] }
      ],
      parallel_result: {
        success: false,
        total: 2,
        completed: 1,
        failed: 0,
        results: [
          { issue_id: 10, task_index: 0, success: true, agent_run_id: 101 },
          { issue_id: 11, task_index: 1, success: false, error: "deadline_exceeded", queued: true }
        ]
      }
    )
  end

  def expect_completed_parallel_observation(observation, project:, issue:, workflow_id:, child_run_ids:)
    expect(observation).to have_attributes(
      project: project,
      issue: issue,
      workflow_id: workflow_id,
      workflow_name: "Workflows::FeatureOrchestrationWorkflow",
      observation_type: "feature_orchestration",
      status: "partial_failure",
      success: false,
      parallel_execution: true,
      task_count: 3,
      dependency_edge_count: 1,
      parallelizable_group_count: 1,
      agent_count_planned: 3,
      agent_count_launched: 3,
      agent_count_succeeded: 2,
      agent_count_failed: 1,
      agent_count_blocked: 0,
      total_iterations: 6,
      max_iterations: 3,
      parallelism_planned: 2,
      parallelism_observed: 2,
      batch_count: 2,
      duration_seconds: 10,
      total_cost_cents: 260,
      total_input_tokens: 900,
      total_output_tokens: 325
    )
    expect(observation.metadata).to include(
      "batch_sizes" => [ 2, 1 ],
      "child_agent_run_ids" => match_array(child_run_ids),
      "error_tally" => { "Agent execution failed" => 1 }
    )
  end
end
