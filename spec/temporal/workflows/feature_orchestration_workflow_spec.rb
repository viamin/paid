# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::FeatureOrchestrationWorkflow do
  let(:workflow) { described_class.new }

  describe "class" do
    it "inherits from BaseWorkflow" do
      expect(described_class.superclass).to eq(Workflows::BaseWorkflow)
    end

    it "is a Temporal workflow definition" do
      expect(described_class).to be < Temporalio::Workflow::Definition
    end
  end

  describe "#execute" do
    let(:input) { { project_id: 1, issue_id: 2 } }

    before do
      stub_temporal_workflow
    end

    def expect_orchestration_sub_issue_creation!
      expect(workflow).to have_received(:run_activity)
        .with(
          Activities::CreateSubIssuesActivity,
          hash_including(
            project_id: 1,
            parent_issue_id: 2,
            creation_mode: Activities::CreateSubIssuesActivity::ORCHESTRATION_MODE,
            sub_tasks: [
              hash_including(title: "Add migration", body: "Create users table", dependencies: []),
              hash_including(title: "Add model", body: "Create User model", dependencies: [ 0 ]),
              hash_including(title: "Add controller", body: "Create UsersController", dependencies: [ 1 ])
            ]
          ),
          timeout: 120,
          retry_policy: anything
        )
    end

    it "accepts a single input parameter" do
      params = workflow.method(:execute).parameters
      expect(params).to eq([ [ :req, :input ] ])
    end

    context "when decomposition produces multiple tasks" do
      let(:tasks) do
        [
          { index: 0, title: "Add migration", description: "Create users table", dependencies: [], parallel_group: 0 },
          { index: 1, title: "Add model", description: "Create User model", dependencies: [ 0 ], parallel_group: 1 },
          { index: 2, title: "Add controller", description: "Create UsersController", dependencies: [ 1 ], parallel_group: 2 }
        ]
      end

      let(:created_issues) { [ { issue_id: 10 }, { issue_id: 11 }, { issue_id: 12 } ] }

      let(:parallel_result) do
        {
          success: true,
          total: 3,
          completed: 3,
          failed: 0,
          results: [
            { issue_id: 10, success: true, agent_run_id: 100 },
            { issue_id: 11, success: true, agent_run_id: 101 },
            { issue_id: 12, success: true, agent_run_id: 102 }
          ],
          conflicts: { has_conflicts: false, conflicting_pairs: [] }
        }
      end

      before do
        stub_planning_activities(tasks: tasks, created_issues: created_issues)
        stub_parallel_execution(parallel_result)
        stub_update_labels
      end

      it "returns success with parallel execution results" do
        result = workflow.execute(input)

        expect(result[:success]).to be true
        expect(result[:project_id]).to eq(1)
        expect(result[:issue_id]).to eq(2)
        expect(result[:task_count]).to eq(3)
        expect(result[:parallel_execution]).to be true
        expect(result[:completed]).to eq(3)
        expect(result[:failed]).to eq(0)
      end

      it "calls planning activities before parallel execution" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(Activities::FetchPlanningContextActivity, hash_including(project_id: 1, issue_id: 2), timeout: 60)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::DecomposeFeatureActivity, hash_including(project_id: 1, issue_id: 2), timeout: 120)
        expect_orchestration_sub_issue_creation!
        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(decision_type: "planning_outcome", outcome: "sub_issues_created"),
            timeout: 30,
            retry_policy: Workflows::FeatureOrchestrationWorkflow::NO_RETRY)
      end

      it "launches ParallelAgentExecutionWorkflow as child workflow" do
        workflow.execute(input)

        expect(Temporalio::Workflow).to have_received(:execute_child_workflow)
          .with(
            Workflows::ParallelAgentExecutionWorkflow,
            hash_including(
              project_id: 1,
              parent_issue_id: 2,
              coordination_policy: hash_including("parallel_execution" => anything),
              sub_tasks: array_including(hash_including(:custom_prompt))
            ),
            hash_including(task_queue: Paid::AGENT_TASK_QUEUE)
          )
      end

      it "records coordination experiment outcomes after parallel execution" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(
            Activities::RecordCoordinationExperimentOutcomeActivity,
            hash_including(
              assignment_id: 77,
              task_count: 3,
              parallel_execution: true
            ),
            timeout: 30,
            retry_policy: Workflows::FeatureOrchestrationWorkflow::NO_RETRY
          )
      end

      it "builds sub_tasks with issue_ids from created issues" do
        workflow.execute(input)

        expect(Temporalio::Workflow).to have_received(:execute_child_workflow)
          .with(
            Workflows::ParallelAgentExecutionWorkflow,
            hash_including(
              sub_tasks: [
                { custom_prompt: "Create users table", issue_id: 10, task_index: 0, dependencies: [], parallel_group: 0 },
                { custom_prompt: "Create User model", issue_id: 11, task_index: 1, dependencies: [ 0 ], parallel_group: 1 },
                { custom_prompt: "Create UsersController", issue_id: 12, task_index: 2, dependencies: [ 1 ], parallel_group: 2 }
              ]
            ),
            anything
          )
      end

      it "updates labels immediately after planning completes" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(Activities::UpdatePlanningLabelsActivity, hash_including(task_count: 3), timeout: 30)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(
              decision_type: "parallelization_outcome",
              outcome: "parallel_execution_planned",
              plan_data: hash_including(sub_tasks: array_including(hash_including(issue_id: 10)))
            ),
            timeout: 30,
            retry_policy: Workflows::FeatureOrchestrationWorkflow::NO_RETRY)
      end

      it "records a scaling observation after parallel execution" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(
            Activities::RecordScalingObservationActivity,
            hash_including(
              project_id: 1,
              issue_id: 2,
              workflow_id: "test-orchestration-wf",
              workflow_name: "Workflows::FeatureOrchestrationWorkflow",
              tasks: tasks,
              parallel_result: hash_including(
                success: true,
                execution_summary: hash_including(max_parallelism_observed: 1)
              )
            ),
            timeout: 30,
            retry_policy: Workflows::FeatureOrchestrationWorkflow::NO_RETRY
          )
      end

      it "passes aggregate_pr option to child workflow when provided" do
        result = workflow.execute(input.merge(aggregate_pr: true))

        expect(result[:success]).to be true
        expect(Temporalio::Workflow).to have_received(:execute_child_workflow)
          .with(
            Workflows::ParallelAgentExecutionWorkflow,
            hash_including(aggregate_pr: true),
            anything
          )
      end

      it "passes timeout_seconds to child workflow" do
        workflow.execute(input.merge(timeout_seconds: 3600))

        expect(Temporalio::Workflow).to have_received(:execute_child_workflow)
          .with(
            Workflows::ParallelAgentExecutionWorkflow,
            hash_including(timeout_seconds: 3600),
            anything
          )
      end
    end

    context "when decomposition produces a single task" do
      let(:tasks) do
        [ { index: 0, title: "Simple fix", description: "Just one task", dependencies: [], parallel_group: 0 } ]
      end

      before do
        stub_planning_activities(tasks: tasks, created_issues: [])
        allow(Temporalio::Workflow).to receive(:execute_child_workflow)
      end

      it "skips parallel execution" do
        result = workflow.execute(input)

        expect(result[:success]).to be true
        expect(result[:parallel_execution]).to be false
        expect(result[:task_count]).to eq(1)
        expect(Temporalio::Workflow).not_to have_received(:execute_child_workflow)
      end

      it "still updates planning labels" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(Activities::UpdatePlanningLabelsActivity, hash_including(task_count: 1), timeout: 30)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(
              decision_type: "parallelization_outcome",
              outcome: "parallel_execution_skipped_single_task"
            ),
            timeout: 30,
            retry_policy: Workflows::FeatureOrchestrationWorkflow::NO_RETRY)
      end

      it "records a skipped scaling observation" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(
            Activities::RecordScalingObservationActivity,
            hash_including(
              project_id: 1,
              issue_id: 2,
              workflow_id: "test-orchestration-wf",
              tasks: tasks
            ),
            timeout: 30,
            retry_policy: Workflows::FeatureOrchestrationWorkflow::NO_RETRY
          )
      end
    end

    context "when decomposition produces no tasks" do
      before do
        stub_planning_activities(tasks: [], created_issues: [])
        allow(Temporalio::Workflow).to receive(:execute_child_workflow)
      end

      it "skips parallel execution" do
        result = workflow.execute(input)

        expect(result[:success]).to be true
        expect(result[:parallel_execution]).to be false
        expect(result[:task_count]).to eq(0)
        expect(Temporalio::Workflow).not_to have_received(:execute_child_workflow)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(outcome: "parallel_execution_skipped_empty_plan"),
            timeout: 30,
            retry_policy: Workflows::FeatureOrchestrationWorkflow::NO_RETRY)
      end
    end

    context "when parallel execution has failures" do
      let(:tasks) do
        [
          { index: 0, title: "Task A", description: "Do A", dependencies: [], parallel_group: 0 },
          { index: 1, title: "Task B", description: "Do B", dependencies: [], parallel_group: 0 }
        ]
      end

      let(:parallel_result) do
        {
          success: false,
          total: 2,
          completed: 1,
          failed: 1,
          results: [
            { issue_id: 10, success: true, agent_run_id: 100 },
            { issue_id: 11, success: false, error: "timeout" }
          ],
          conflicts: { has_conflicts: false, conflicting_pairs: [] }
        }
      end

      before do
        stub_planning_activities(tasks: tasks, created_issues: [ { issue_id: 10 }, { issue_id: 11 } ])
        stub_parallel_execution(parallel_result)
        stub_update_labels
      end

      it "returns failure with details" do
        result = workflow.execute(input)

        expect(result[:success]).to be false
        expect(result[:completed]).to eq(1)
        expect(result[:failed]).to eq(1)
      end
    end

    context "when parallel execution detects conflicts" do
      let(:tasks) do
        [
          { index: 0, title: "Task A", description: "Do A", dependencies: [], parallel_group: 0 },
          { index: 1, title: "Task B", description: "Do B", dependencies: [], parallel_group: 0 }
        ]
      end

      let(:parallel_result) do
        {
          success: true,
          total: 2,
          completed: 2,
          failed: 0,
          results: [],
          conflicts: { has_conflicts: true, conflicting_pairs: [ { run_a: 100, run_b: 101, files: [ "app/models/user.rb" ] } ] }
        }
      end

      before do
        stub_planning_activities(tasks: tasks, created_issues: [ { issue_id: 10 }, { issue_id: 11 } ])
        stub_parallel_execution(parallel_result)
        stub_update_labels
      end

      it "includes conflict information in results" do
        result = workflow.execute(input)

        expect(result[:conflicts][:has_conflicts]).to be true
        expect(result[:conflicts][:conflicting_pairs]).not_to be_empty
      end
    end

    context "when created issue has nil issue_id" do
      let(:tasks) do
        [
          { index: 0, title: "Task A", description: "Do A", dependencies: [], parallel_group: 0 },
          { index: 1, title: "Task B", description: "Do B", dependencies: [], parallel_group: 0 }
        ]
      end

      before do
        stub_planning_activities(tasks: tasks, created_issues: [ { issue_id: 10 }, { issue_id: nil } ])
      end

      it "raises a non-retryable error" do
        expect { workflow.execute(input) }.to raise_error(
          Temporalio::Error::ApplicationError,
          /returned nil issue_id for task 1: Task B/
        )
        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(
              decision_type: "parallelization_outcome",
              outcome: "parallelization_planning_failed"
            ),
            timeout: 30,
            retry_policy: Workflows::FeatureOrchestrationWorkflow::NO_RETRY)
      end
    end

    context "when decompose returns nil tasks" do
      before do
        stub_planning_activities(tasks: nil, created_issues: [])
        allow(Temporalio::Workflow).to receive(:execute_child_workflow)
      end

      it "defaults to empty array and skips parallel execution" do
        result = workflow.execute(input)

        expect(result[:success]).to be true
        expect(result[:parallel_execution]).to be false
        expect(result[:task_count]).to eq(0)
      end
    end

    context "when an activity raises an error" do
      before do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::ResolveCoordinationExperimentActivity"
            { assignment_id: 77, coordination_policy: OrchestrationStrategies::Defaults.feature_orchestration }
          when "Activities::FetchPlanningContextActivity"
            { context: {} }
          when "Activities::DecomposeFeatureActivity"
            raise Temporalio::Error::ApplicationError.new("LLM failed", type: "DecompositionFailed")
          when "Activities::RecordCoordinationExperimentOutcomeActivity"
            { assignment_id: 77, outcome_status: "recorded" }
          when "Activities::LogDecompositionDecisionActivity"
            { decomposition_decision_id: 9 }
          else
            {}
          end
        end
      end

      it "re-raises the error" do
        expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError, "LLM failed")
        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(
              decision_type: "planning_outcome",
              outcome: "decomposition_failed"
            ),
            timeout: 30,
            retry_policy: Workflows::FeatureOrchestrationWorkflow::NO_RETRY)
        expect_failed_scaling_observation_recorded!
      end
    end

    context "with aggregated PR result" do
      let(:tasks) do
        [
          { index: 0, title: "Task A", description: "Do A", dependencies: [], parallel_group: 0 },
          { index: 1, title: "Task B", description: "Do B", dependencies: [], parallel_group: 0 }
        ]
      end

      let(:parallel_result) do
        {
          success: true,
          total: 2,
          completed: 2,
          failed: 0,
          results: [],
          conflicts: { has_conflicts: false, conflicting_pairs: [] },
          aggregated_pr: { pull_request_url: "https://github.com/org/repo/pull/42" }
        }
      end

      before do
        stub_planning_activities(tasks: tasks, created_issues: [ { issue_id: 10 }, { issue_id: 11 } ])
        stub_parallel_execution(parallel_result)
        stub_update_labels
      end

      it "includes aggregated PR in results" do
        result = workflow.execute(input)

        expect(result[:aggregated_pr]).to eq({ pull_request_url: "https://github.com/org/repo/pull/42" })
      end
    end

    context "when created issues are returned in dependency order" do
      let(:tasks) do
        [
          { index: 0, title: "Task A", description: "Do A", dependencies: [], parallel_group: 0 },
          { index: 1, title: "Task B", description: "Do B", dependencies: [ 0 ], parallel_group: 1 },
          { index: 2, title: "Task C", description: "Do C", dependencies: [], parallel_group: 0 }
        ]
      end

      let(:parallel_result) do
        {
          success: true,
          total: 3,
          completed: 3,
          failed: 0,
          results: [],
          conflicts: { has_conflicts: false, conflicting_pairs: [] }
        }
      end

      before do
        stub_planning_activities(
          tasks: tasks,
          created_issues: [ { index: 0, issue_id: 10 }, { index: 2, issue_id: 12 }, { index: 1, issue_id: 11 } ]
        )
        stub_parallel_execution(parallel_result)
        stub_update_labels
      end

      it "maps created issues back to the original task index" do
        workflow.execute(input)

        expect(Temporalio::Workflow).to have_received(:execute_child_workflow)
          .with(
            Workflows::ParallelAgentExecutionWorkflow,
            hash_including(
              sub_tasks: [
                hash_including(issue_id: 10, task_index: 0),
                hash_including(issue_id: 11, task_index: 1),
                hash_including(issue_id: 12, task_index: 2)
              ]
            ),
            anything
          )
      end
    end
  end

  private

  def stub_temporal_workflow
    workflow_info = Struct.new(:workflow_id).new("test-orchestration-wf")
    allow(Temporalio::Workflow).to receive_messages(
      logger: Rails.logger,
      info: workflow_info,
      now: Time.current
    )
    allow(Temporalio::Workflow).to receive(:execute_child_workflow)
  end

  def stub_planning_activities(tasks:, created_issues:)
    allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
      case activity_class.name
      when "Activities::ResolveCoordinationExperimentActivity"
        { assignment_id: 77, coordination_policy: OrchestrationStrategies::Defaults.feature_orchestration }
      when "Activities::FetchPlanningContextActivity"
        { context: { issue_title: "Feature", knowledge_snippets: [] } }
      when "Activities::DecomposeFeatureActivity"
        { tasks: tasks }
      when "Activities::CreateSubIssuesActivity"
        { created_issues: created_issues }
      when "Activities::UpdatePlanningLabelsActivity"
        { success: true }
      when "Activities::RecordCoordinationExperimentOutcomeActivity"
        { assignment_id: 77, outcome_status: "recorded" }
      when "Activities::LogDecompositionDecisionActivity"
        { decomposition_decision_id: 1 }
      when "Activities::RecordScalingObservationActivity"
        { scaling_observation_id: 1 }
      else
        {}
      end
    end
  end

  def stub_parallel_execution(result)
    allow(Temporalio::Workflow).to receive(:execute_child_workflow)
      .with(Workflows::ParallelAgentExecutionWorkflow, anything, anything)
      .and_return(result.deep_merge(execution_summary: { batch_count: result[:total], batch_sizes: Array.new(result[:total], 1), max_parallelism_observed: 1 }))
  end

  def stub_update_labels
    # Already handled by stub_planning_activities
  end

  def expect_failed_scaling_observation_recorded!
    expect(workflow).to have_received(:run_activity)
      .with(
        Activities::RecordScalingObservationActivity,
        hash_including(
          project_id: 1,
          issue_id: 2,
          workflow_id: "test-orchestration-wf",
          error_details: hash_including(
            error_class: "Temporalio::Error::ApplicationError",
            error_message: "LLM failed",
            failed_step: "decompose_feature"
          )
        ),
        timeout: 30,
        retry_policy: Workflows::FeatureOrchestrationWorkflow::NO_RETRY
      )
  end
end
