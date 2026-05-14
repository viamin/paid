# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::PlanningWorkflow, :no_db do
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
      workflow_info = Struct.new(:workflow_id).new("test-planning-wf")
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, info: workflow_info)
    end

    def expect_decompose_feature_activity_called
      expect(workflow).to have_received(:run_activity)
        .with(
          Activities::DecomposeFeatureActivity,
          hash_including(
            project_id: 1,
            issue_id: 2,
            workflow_name: "Workflows::PlanningWorkflow",
            workflow_id: "test-planning-wf"
          ),
          timeout: 120
        )
    end

    def policy_metadata_payload
      {
        policy_source: "coordination_policy",
        policy_key: "feature_decomposition",
        coordination_policy_id: 12,
        coordination_policy_version_id: 34,
        coordination_policy_version: 5
      }
    end

    def stub_policy_driven_decomposition(tasks)
      allow(workflow).to receive(:run_activity) do |activity_class, _activity_input, **_opts|
        case activity_class.name
        when "Activities::FetchPlanningContextActivity"
          { context: { issue_title: "Feature", knowledge_snippets: [] } }
        when "Activities::DecomposeFeatureActivity"
          {
            tasks: tasks,
            prompt_source: "policy_service",
            policy_metadata: policy_metadata_payload
          }
        when "Activities::CreateSubIssuesActivity"
          { created_issues: [ { issue_id: 10 }, { issue_id: 11 }, { issue_id: 12 } ] }
        when "Activities::UpdatePlanningLabelsActivity"
          { success: true }
        when "Activities::LogDecompositionDecisionActivity"
          { decomposition_decision_id: 1 }
        else
          {}
        end
      end
    end

    def stub_top_level_policy_driven_decomposition(tasks)
      allow(workflow).to receive(:run_activity) do |activity_class, _activity_input, **_opts|
        case activity_class.name
        when "Activities::FetchPlanningContextActivity"
          { context: { issue_title: "Feature", knowledge_snippets: [] } }
        when "Activities::DecomposeFeatureActivity"
          {
            tasks: tasks,
            prompt_source: "policy_service",
            **policy_metadata_payload
          }
        when "Activities::CreateSubIssuesActivity"
          { created_issues: [ { issue_id: 10 }, { issue_id: 11 }, { issue_id: 12 } ] }
        when "Activities::UpdatePlanningLabelsActivity"
          { success: true }
        when "Activities::LogDecompositionDecisionActivity"
          { decomposition_decision_id: 1 }
        else
          {}
        end
      end
    end

    it "accepts a single input parameter" do
      params = workflow.method(:execute).parameters
      expect(params).to eq([ [ :req, :input ] ])
    end


    context "when decomposition produces multiple tasks" do
      let(:tasks) do
        [
          { index: 0, title: "Add migration", description: "Create table", dependencies: [], parallel_group: 0 },
          { index: 1, title: "Add model", description: "Create model", dependencies: [ 0 ], parallel_group: 1 },
          { index: 2, title: "Add controller", description: "Create endpoint", dependencies: [ 1 ], parallel_group: 2 }
        ]
      end

      before do
        allow(workflow).to receive(:run_activity) do |activity_class, activity_input, **_opts|
          case activity_class.name
          when "Activities::FetchPlanningContextActivity"
            { context: { issue_title: "Feature", knowledge_snippets: [] } }
          when "Activities::DecomposeFeatureActivity"
            { tasks: tasks }
          when "Activities::CreateSubIssuesActivity"
            { created_issues: [ { issue_id: 10 }, { issue_id: 11 }, { issue_id: 12 } ] }
          when "Activities::UpdatePlanningLabelsActivity"
            { success: true }
          when "Activities::LogDecompositionDecisionActivity"
            { decomposition_decision_id: 1 }
          else
            {}
          end
        end
      end

      it "returns success with created issues" do
        result = workflow.execute(input)

        expect(result[:success]).to be true
        expect(result[:task_count]).to eq(3)
        expect(result[:created_issues]).to eq([ { issue_id: 10 }, { issue_id: 11 }, { issue_id: 12 } ])
      end

      it "calls the planning activities in sequence" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(Activities::FetchPlanningContextActivity, hash_including(project_id: 1, issue_id: 2), timeout: 60)
        expect_decompose_feature_activity_called
        expected_sub_tasks = tasks.map { |t| { title: t[:title], body: t[:description] } }
        expect(workflow).to have_received(:run_activity)
          .with(Activities::CreateSubIssuesActivity,
            hash_including(project_id: 1, parent_issue_id: 2, sub_tasks: expected_sub_tasks),
            timeout: 120, retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::UpdatePlanningLabelsActivity, hash_including(project_id: 1, issue_id: 2, task_count: 3), timeout: 30)
      end

      it "logs the final planning decision" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(
              workflow_name: "Workflows::PlanningWorkflow",
              decision_type: "planning_outcome",
              outcome: "sub_issues_created",
              plan_data: hash_including(tasks: tasks),
              metadata: hash_including(prompt_source: nil)
            ),
            timeout: 30,
            retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
      end

      it "propagates decomposition policy metadata into planning outcome logs" do
        stub_policy_driven_decomposition(tasks)

        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(
            Activities::LogDecompositionDecisionActivity,
            hash_including(
              metadata: hash_including(prompt_source: "policy_service", **policy_metadata_payload)
            ),
            timeout: 30,
            retry_policy: Workflows::PlanningWorkflow::NO_RETRY
          )
      end

      it "propagates top-level provenance when policy_metadata is omitted" do
        stub_top_level_policy_driven_decomposition(tasks)

        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(
            Activities::LogDecompositionDecisionActivity,
            hash_including(
              metadata: hash_including(prompt_source: "policy_service", **policy_metadata_payload)
            ),
            timeout: 30,
            retry_policy: Workflows::PlanningWorkflow::NO_RETRY
          )
      end
    end

    context "when decomposition produces a single task" do
      let(:tasks) do
        [ { index: 0, title: "Simple change", description: "Just do it", dependencies: [], parallel_group: 0 } ]
      end

      before do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::FetchPlanningContextActivity"
            { context: {} }
          when "Activities::DecomposeFeatureActivity"
            { tasks: tasks, prompt_source: "fallback_prompt", policy_metadata: { policy_source: "defaults" } }
          when "Activities::UpdatePlanningLabelsActivity"
            { success: true }
          when "Activities::LogDecompositionDecisionActivity"
            { decomposition_decision_id: 2 }
          else
            {}
          end
        end
      end

      it "skips sub-issue creation for single-task features" do
        result = workflow.execute(input)

        expect(result[:success]).to be true
        expect(result[:task_count]).to eq(1)
        expect(result[:created_issues]).to eq([])
        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::CreateSubIssuesActivity, anything, any_args)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(
              outcome: "single_task_plan",
              metadata: hash_including(prompt_source: "fallback_prompt", policy_source: "defaults")
            ),
            timeout: 30,
            retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
      end
    end

    context "when decomposition produces no tasks" do
      before do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::FetchPlanningContextActivity"
            { context: {} }
          when "Activities::DecomposeFeatureActivity"
            { tasks: [], policy_metadata: { policy_source: "feature_orchestration", skip_reason: "below_complexity_threshold" } }
          when "Activities::UpdatePlanningLabelsActivity"
            { success: true }
          when "Activities::LogDecompositionDecisionActivity"
            { decomposition_decision_id: 3 }
          else
            {}
          end
        end
      end

      it "skips sub-issue creation when no tasks" do
        result = workflow.execute(input)

        expect(result[:success]).to be true
        expect(result[:task_count]).to eq(0)
        expect(result[:created_issues]).to eq([])
        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(
              outcome: "empty_plan",
              metadata: hash_including(
                policy_source: "feature_orchestration",
                skip_reason: "below_complexity_threshold"
              )
            ),
            timeout: 30,
            retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
      end
    end

    context "when an activity raises an error" do
      before do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::FetchPlanningContextActivity"
            { context: {} }
          when "Activities::DecomposeFeatureActivity"
            raise Temporalio::Error::ApplicationError.new("LLM failed", type: "DecompositionFailed")
          when "Activities::LogDecompositionDecisionActivity"
            { decomposition_decision_id: 4 }
          else
            {}
          end
        end
      end

      it "re-raises the error" do
        expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(
              decision_type: "planning_outcome",
              outcome: "decomposition_failed",
              error_details: hash_including(error_message: "LLM failed")
            ),
            timeout: 30,
            retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
      end
    end
  end
end
