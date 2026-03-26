# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::Cancel do
  describe ".call" do
    let(:agent_run) { create(:agent_run, status: "running", started_at: 2.minutes.ago) }

    it "marks the run as cancelled" do
      described_class.call(agent_run: agent_run)

      expect(agent_run.reload.status).to eq("cancelled")
    end

    it "cancels the Temporal workflow when present" do
      handle = double(cancel: true)
      agent_run.update!(temporal_workflow_id: "workflow-123")

      allow(Paid.temporal_client).to receive(:workflow_handle).with("workflow-123").and_return(handle)

      described_class.call(agent_run: agent_run)

      expect(handle).to have_received(:cancel)
    end

    it "ignores not-found Temporal workflow errors" do
      error = Temporalio::Error::RPCError.allocate
      allow(error).to receive(:code).and_return(Temporalio::Error::RPCError::Code::NOT_FOUND)
      agent_run.update!(temporal_workflow_id: "workflow-123")

      handle = double
      allow(handle).to receive(:cancel).and_raise(error)
      allow(Paid.temporal_client).to receive(:workflow_handle).with("workflow-123").and_return(handle)

      expect { described_class.call(agent_run: agent_run) }.not_to raise_error
    end

    it "cleans up the container when present" do
      agent_run.update!(container_id: "container-123")
      allow(agent_run).to receive(:cleanup_container)

      described_class.call(agent_run: agent_run)

      expect(agent_run).to have_received(:cleanup_container).with(force: true)
    end
  end
end
