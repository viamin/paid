# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkflowState do
  describe "associations" do
    it { is_expected.to belong_to(:project).optional }
  end

  describe "validations" do
    subject { build(:workflow_state) }

    it { is_expected.to validate_presence_of(:temporal_workflow_id) }
    it { is_expected.to validate_uniqueness_of(:temporal_workflow_id) }
    it { is_expected.to validate_presence_of(:workflow_type) }
    it { is_expected.to validate_presence_of(:status) }
  end

  describe "scopes" do
    describe ".active" do
      it "includes running workflows" do
        running_workflow = create(:workflow_state, status: :running)
        expect(described_class.active).to include(running_workflow)
      end

      it "excludes completed workflows" do
        completed_workflow = create(:workflow_state, :completed)
        expect(described_class.active).not_to include(completed_workflow)
      end
    end

    describe ".finished" do
      it "includes completed workflows" do
        completed_workflow = create(:workflow_state, :completed)
        expect(described_class.finished).to include(completed_workflow)
      end

      it "includes failed workflows" do
        failed_workflow = create(:workflow_state, :failed)
        expect(described_class.finished).to include(failed_workflow)
      end

      it "includes cancelled workflows" do
        cancelled_workflow = create(:workflow_state, :cancelled)
        expect(described_class.finished).to include(cancelled_workflow)
      end

      it "includes timed_out workflows" do
        timed_out_workflow = create(:workflow_state, :timed_out)
        expect(described_class.finished).to include(timed_out_workflow)
      end

      it "excludes running workflows" do
        running_workflow = create(:workflow_state, status: :running)
        expect(described_class.finished).not_to include(running_workflow)
      end
    end
  end

  describe "status enum" do
    it "defaults to running" do
      workflow_state = described_class.new(
        temporal_workflow_id: "test-id",
        workflow_type: "TestWorkflow"
      )
      expect(workflow_state.status).to eq("running")
    end

    it "accepts all valid statuses" do
      expect(described_class.statuses.keys).to contain_exactly(
        "running", "completed", "failed", "cancelled", "timed_out"
      )
    end
  end

  describe "JSONB storage" do
    it "stores input_data as JSONB" do
      input = { issue_id: 123, prompt: "Test prompt" }
      workflow_state = create(:workflow_state, input_data: input)
      reloaded = described_class.find(workflow_state.id)

      expect(reloaded.input_data).to eq(input.stringify_keys)
    end

    it "stores result_data as JSONB" do
      result = { pr_url: "https://github.com/example/repo/pull/1" }
      workflow_state = create(:workflow_state, result_data: result)
      reloaded = described_class.find(workflow_state.id)

      expect(reloaded.result_data).to eq(result.stringify_keys)
    end
  end
end
