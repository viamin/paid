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
      allow(Temporalio::Workflow).to receive(:patched)
        .with("planning-review-signal-gate-v1")
        .and_return(true)
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

    def stub_review_gate(timeout: true)
      if timeout
        allow(Temporalio::Workflow).to receive(:sleep)
      end
      allow(Temporalio::Cancellation).to receive(:new).and_return([ double, -> { } ])
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
        stub_review_gate(timeout: true)
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

      it "logs the pending review and timeout decisions" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(decision_key: "test-planning-wf:plan_review:pending", outcome: "plan_pending_review"),
            timeout: 30, retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(decision_key: "test-planning-wf:plan_review:timed_out", outcome: "plan_review_timed_out"),
            timeout: 30, retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
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
              decision_key: "test-planning-wf:planning_outcome:final",
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
              decision_key: "test-planning-wf:planning_outcome:final",
              metadata: hash_including(prompt_source: "policy_service", **policy_metadata_payload)
            ),
            timeout: 30,
            retry_policy: Workflows::PlanningWorkflow::NO_RETRY
          )
      end
    end

    context "when replaying an execution that started before the review gate patch" do
      let(:tasks) do
        [
          { index: 0, title: "Add migration", description: "Create table", dependencies: [], parallel_group: 0 },
          { index: 1, title: "Add model", description: "Create model", dependencies: [ 0 ], parallel_group: 1 }
        ]
      end

      before do
        allow(Temporalio::Workflow).to receive(:patched)
          .with("planning-review-signal-gate-v1")
          .and_return(false)
        allow(Temporalio::Workflow).to receive(:sleep)

        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::FetchPlanningContextActivity"
            { context: { issue_title: "Feature", knowledge_snippets: [] } }
          when "Activities::DecomposeFeatureActivity"
            { tasks: tasks }
          when "Activities::CreateSubIssuesActivity"
            { created_issues: [ { issue_id: 10 }, { issue_id: 11 } ] }
          when "Activities::UpdatePlanningLabelsActivity"
            { success: true }
          when "Activities::LogDecompositionDecisionActivity"
            { decomposition_decision_id: 1 }
          else
            {}
          end
        end
      end

      it "skips the review timer and continues on the pre-patch path" do
        result = workflow.execute(input)

        expect(result[:success]).to be true
        expect(result[:created_issues]).to eq([ { issue_id: 10 }, { issue_id: 11 } ])
        expect(Temporalio::Workflow).not_to have_received(:sleep)
        expect(workflow).not_to have_received(:run_activity)
          .with(
            Activities::LogDecompositionDecisionActivity,
            hash_including(outcome: "plan_pending_review"),
            any_args
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

      it "does not enter the plan review gate" do
        workflow.execute(input)

        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity,
            hash_including(outcome: "plan_pending_review"),
            any_args)
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
      let(:failure_policy_metadata) do
        {
          policy_source: "coordination_policy",
          policy_key: "feature_decomposition",
          coordination_policy_id: 12,
          coordination_policy_version_id: 34,
          coordination_policy_version: 5
        }
      end

      before do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::FetchPlanningContextActivity"
            { context: {} }
          when "Activities::DecomposeFeatureActivity"
            raise Temporalio::Error::ApplicationError.new(
              "LLM failed",
              { policy_metadata: failure_policy_metadata },
              type: "DecompositionFailed"
            )
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
              error_details: hash_including(error_message: "LLM failed"),
              metadata: hash_including(**failure_policy_metadata)
            ),
            cancellation: an_instance_of(Temporalio::Cancellation),
            timeout: 30,
            retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
      end

      it "does not log a failure activity on cancellation" do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::FetchPlanningContextActivity"
            { context: {} }
          when "Activities::DecomposeFeatureActivity"
            raise Temporalio::Error::CanceledError, "workflow canceled"
          else
            raise "unexpected activity #{activity_class.name}"
          end
        end

        expect { workflow.execute(input) }.to raise_error(Temporalio::Error::CanceledError)
        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::LogDecompositionDecisionActivity, anything, any_args)
      end
    end

    context "with plan review signal gate" do
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
        allow(Temporalio::Cancellation).to receive(:new).and_return([ double, -> { } ])
      end

      context "when approve_plan signal arrives" do
        before do
          allow(Temporalio::Workflow).to receive(:sleep) { workflow.approve_plan }
        end

        it "creates sub-issues" do
          result = workflow.execute(input)

          expect(result[:success]).to be true
          expect(result[:created_issues]).to eq([ { issue_id: 10 }, { issue_id: 11 }, { issue_id: 12 } ])
        end

        it "logs the approved review decision" do
          workflow.execute(input)

          expect(workflow).to have_received(:run_activity)
            .with(Activities::LogDecompositionDecisionActivity,
              hash_including(decision_key: "test-planning-wf:plan_review:approved", outcome: "plan_review_approved"),
              timeout: 30, retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
        end
      end

      context "when approve_plan arrives while pending review is still being logged" do
        before do
          allow(Temporalio::Workflow).to receive(:sleep)
          allow(workflow).to receive(:run_activity) do |activity_class, activity_input, **_opts|
            case activity_class.name
            when "Activities::FetchPlanningContextActivity"
              { context: { issue_title: "Feature", knowledge_snippets: [] } }
            when "Activities::DecomposeFeatureActivity"
              { tasks: tasks }
            when "Activities::LogDecompositionDecisionActivity"
              workflow.approve_plan if activity_input[:decision_key] == "test-planning-wf:plan_review:pending"
              { decomposition_decision_id: 1 }
            when "Activities::CreateSubIssuesActivity"
              { created_issues: [ { issue_id: 10 }, { issue_id: 11 }, { issue_id: 12 } ] }
            when "Activities::UpdatePlanningLabelsActivity"
              { success: true }
            else
              {}
            end
          end
        end

        it "does not lose the signal or sleep until timeout" do
          result = workflow.execute(input)

          expect(result[:success]).to be true
          expect(result[:created_issues]).to eq([ { issue_id: 10 }, { issue_id: 11 }, { issue_id: 12 } ])
          expect(Temporalio::Workflow).not_to have_received(:sleep)
          expect(workflow).to have_received(:run_activity)
            .with(Activities::LogDecompositionDecisionActivity,
              hash_including(decision_key: "test-planning-wf:plan_review:approved", outcome: "plan_review_approved"),
              timeout: 30, retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
        end
      end

      context "when reject_plan signal arrives" do
        before do
          allow(Temporalio::Workflow).to receive(:sleep) { workflow.reject_plan }
        end

        it "skips sub-issue creation" do
          result = workflow.execute(input)

          expect(result[:success]).to be true
          expect(result[:task_count]).to eq(3)
          expect(result[:created_issues]).to eq([])
          expect(workflow).not_to have_received(:run_activity)
            .with(Activities::CreateSubIssuesActivity, anything, any_args)
        end

        it "logs the rejected outcome" do
          workflow.execute(input)

          expect(workflow).to have_received(:run_activity)
            .with(Activities::LogDecompositionDecisionActivity,
              hash_including(
                decision_key: "test-planning-wf:planning_outcome:final",
                outcome: "plan_review_rejected"
              ),
              timeout: 30,
              retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
        end
      end

      context "when revise_plan signal arrives" do
        let(:revised_tasks) do
          [
            { title: "Revised task 1", description: "Better approach" },
            { title: "Revised task 2", description: "Follow-up implementation" }
          ]
        end

        before do
          allow(Temporalio::Workflow).to receive(:sleep) { workflow.revise_plan(revised_tasks) }
        end

        it "creates sub-issues with revised tasks" do
          workflow.execute(input)

          expected = revised_tasks.map { |t| { title: t[:title], body: t[:description] } }
          expect(workflow).to have_received(:run_activity)
            .with(Activities::CreateSubIssuesActivity,
              hash_including(sub_tasks: expected),
              timeout: 120, retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
        end
      end

      context "when revise_plan collapses the plan to one task" do
        let(:revised_tasks) do
          [
            { title: "Revised task", description: "Better approach" }
          ]
        end

        before do
          allow(Temporalio::Workflow).to receive(:sleep) { workflow.revise_plan(revised_tasks) }
        end

        it "skips sub-issue creation" do
          result = workflow.execute(input)

          expect(result[:success]).to be true
          expect(result[:task_count]).to eq(1)
          expect(result[:created_issues]).to eq([])
          expect(workflow).not_to have_received(:run_activity)
            .with(Activities::CreateSubIssuesActivity, anything, any_args)
        end

        it "logs the reviewed plan outcome and updates labels with the revised count" do
          workflow.execute(input)

          expect(workflow).to have_received(:run_activity)
            .with(Activities::UpdatePlanningLabelsActivity,
              hash_including(project_id: 1, issue_id: 2, task_count: 1),
              timeout: 30)
          expect(workflow).to have_received(:run_activity)
            .with(Activities::LogDecompositionDecisionActivity,
              hash_including(
                decision_key: "test-planning-wf:planning_outcome:final",
                outcome: "single_task_plan",
                plan_data: hash_including(tasks: revised_tasks)
              ),
              timeout: 30,
              retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
        end
      end

      context "when revise_plan clears the plan" do
        let(:revised_tasks) { [] }

        before do
          allow(Temporalio::Workflow).to receive(:sleep) { workflow.revise_plan(revised_tasks) }
        end

        it "returns an empty plan without creating sub-issues" do
          result = workflow.execute(input)

          expect(result[:success]).to be true
          expect(result[:task_count]).to eq(0)
          expect(result[:created_issues]).to eq([])
          expect(workflow).not_to have_received(:run_activity)
            .with(Activities::CreateSubIssuesActivity, anything, any_args)
        end

        it "logs the empty reviewed plan outcome" do
          workflow.execute(input)

          expect(workflow).to have_received(:run_activity)
            .with(Activities::LogDecompositionDecisionActivity,
              hash_including(
                decision_key: "test-planning-wf:planning_outcome:final",
                outcome: "empty_plan",
                plan_data: hash_including(tasks: [])
              ),
              timeout: 30,
              retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
        end
      end

      context "when timeout occurs" do
        before do
          allow(Temporalio::Workflow).to receive(:sleep)
        end

        it "auto-approves and creates sub-issues" do
          result = workflow.execute(input)

          expect(result[:success]).to be true
          expect(result[:created_issues]).to eq([ { issue_id: 10 }, { issue_id: 11 }, { issue_id: 12 } ])
        end

        it "logs the timeout review decision" do
          workflow.execute(input)

          expect(workflow).to have_received(:run_activity)
            .with(Activities::LogDecompositionDecisionActivity,
              hash_including(decision_key: "test-planning-wf:plan_review:timed_out", outcome: "plan_review_timed_out"),
              timeout: 30, retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
        end
      end
    end
  end
end
