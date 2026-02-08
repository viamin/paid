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
        running_workflow = create(:workflow_state, status: "running")
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
        running_workflow = create(:workflow_state, status: "running")
        expect(described_class.finished).not_to include(running_workflow)
      end
    end
  end

  describe "status constants" do
    it "defines all valid statuses" do
      expect(described_class::STATUSES).to contain_exactly(
        "running", "completed", "failed", "cancelled", "timed_out"
      )
    end

    it "validates status inclusion" do
      workflow_state = build(:workflow_state, status: "invalid")
      expect(workflow_state).not_to be_valid
      expect(workflow_state.errors[:status]).to include("is not included in the list")
    end
  end

  describe "instance methods" do
    describe "#running?" do
      it "returns true when status is running" do
        workflow_state = build(:workflow_state, status: "running")
        expect(workflow_state.running?).to be true
      end

      it "returns false when status is not running" do
        workflow_state = build(:workflow_state, :completed)
        expect(workflow_state.running?).to be false
      end
    end

    describe "#finished?" do
      it "returns true for completed status" do
        workflow_state = build(:workflow_state, :completed)
        expect(workflow_state.finished?).to be true
      end

      it "returns true for failed status" do
        workflow_state = build(:workflow_state, :failed)
        expect(workflow_state.finished?).to be true
      end

      it "returns true for cancelled status" do
        workflow_state = build(:workflow_state, :cancelled)
        expect(workflow_state.finished?).to be true
      end

      it "returns true for timed_out status" do
        workflow_state = build(:workflow_state, :timed_out)
        expect(workflow_state.finished?).to be true
      end

      it "returns false for running status" do
        workflow_state = build(:workflow_state, status: "running")
        expect(workflow_state.finished?).to be false
      end
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
