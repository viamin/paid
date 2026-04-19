# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::PropagateFailure do
  let(:workflow_id) { "fail-workflow-#{SecureRandom.hex(4)}" }
  let(:project) { create(:project) }
  let(:failed_run) do
    create(:agent_run, :failed, project: project, parent_workflow_id: workflow_id,
      error_message: "Agent execution timed out")
  end

  describe ".call" do
    it "broadcasts a dependency_failed signal" do
      result = described_class.call(failed_agent_run: failed_run)

      expect(result).to be_success
      expect(result.signal).to be_persisted
      expect(result.signal.signal_type).to eq("dependency_failed")
      expect(result.signal.payload["error_message"]).to eq("Agent execution timed out")
      expect(result.signal.payload["failed_status"]).to eq("failed")
    end

    it "cancels queued dependent runs when cancel_dependents is true" do
      queued_run = create(:agent_run, :queued, project: project, parent_workflow_id: workflow_id)
      pending_run = create(:agent_run, project: project, parent_workflow_id: workflow_id, status: "pending")

      result = described_class.call(
        failed_agent_run: failed_run,
        cancel_dependents: true
      )

      expect(result).to be_success
      expect(result.cancelled_run_ids).to contain_exactly(queued_run.id, pending_run.id)
      expect(queued_run.reload.status).to eq("cancelled")
      expect(pending_run.reload.status).to eq("cancelled")
    end

    it "does not cancel runs from other workflows" do
      other_run = create(:agent_run, :queued, project: project, parent_workflow_id: "other-workflow")

      described_class.call(
        failed_agent_run: failed_run,
        cancel_dependents: true
      )

      expect(other_run.reload.status).to eq("queued")
    end

    it "only cancels specific dependent runs when dependent_run_ids given" do
      queued_a = create(:agent_run, :queued, project: project, parent_workflow_id: workflow_id)
      queued_b = create(:agent_run, :queued, project: project, parent_workflow_id: workflow_id)

      result = described_class.call(
        failed_agent_run: failed_run,
        dependent_run_ids: [ queued_a.id ],
        cancel_dependents: true
      )

      expect(result.cancelled_run_ids).to contain_exactly(queued_a.id)
      expect(queued_b.reload.status).to eq("queued")
    end

    it "fails when failed run has no parent_workflow_id" do
      run = create(:agent_run, :failed, project: project, parent_workflow_id: nil)

      result = described_class.call(failed_agent_run: run)

      expect(result).not_to be_success
      expect(result.error).to include("no parent_workflow_id")
    end
  end
end
