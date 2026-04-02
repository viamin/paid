# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::PlanningWorkflow do
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
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger)
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
            { sub_issue_ids: [ 10, 11, 12 ] }
          when "Activities::UpdatePlanningLabelsActivity"
            { success: true }
          else
            {}
          end
        end
      end

      it "returns success with sub-issue IDs" do
        result = workflow.execute(input)

        expect(result[:success]).to be true
        expect(result[:task_count]).to eq(3)
        expect(result[:sub_issue_ids]).to eq([ 10, 11, 12 ])
      end

      it "calls all four activities in sequence" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(Activities::FetchPlanningContextActivity, hash_including(project_id: 1, issue_id: 2), timeout: 60)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::DecomposeFeatureActivity, hash_including(project_id: 1, issue_id: 2), timeout: 120)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::CreateSubIssuesActivity, hash_including(project_id: 1, parent_issue_id: 2, tasks: tasks),
            timeout: 120, retry_policy: Workflows::PlanningWorkflow::NO_RETRY)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::UpdatePlanningLabelsActivity, hash_including(project_id: 1, issue_id: 2, task_count: 3), timeout: 30)
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
            { tasks: tasks }
          when "Activities::UpdatePlanningLabelsActivity"
            { success: true }
          else
            {}
          end
        end
      end

      it "skips sub-issue creation for single-task features" do
        result = workflow.execute(input)

        expect(result[:success]).to be true
        expect(result[:task_count]).to eq(1)
        expect(result[:sub_issue_ids]).to eq([])
        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::CreateSubIssuesActivity, anything, any_args)
      end
    end

    context "when decomposition produces no tasks" do
      before do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::FetchPlanningContextActivity"
            { context: {} }
          when "Activities::DecomposeFeatureActivity"
            { tasks: [] }
          when "Activities::UpdatePlanningLabelsActivity"
            { success: true }
          else
            {}
          end
        end
      end

      it "skips sub-issue creation when no tasks" do
        result = workflow.execute(input)

        expect(result[:success]).to be true
        expect(result[:task_count]).to eq(0)
        expect(result[:sub_issue_ids]).to eq([])
      end
    end

    context "when an activity raises an error" do
      before do
        allow(workflow).to receive(:run_activity)
          .and_raise(Temporalio::Error::ApplicationError.new("LLM failed", type: "DecompositionFailed"))
      end

      it "re-raises the error" do
        expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError)
      end
    end
  end
end
