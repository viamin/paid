# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunCancellationJob, type: :job do
  describe "#perform" do
    let(:agent_run) { create(:agent_run, status: "cancelled", completed_at: Time.current) }

    it "cancels the Temporal workflow when present" do
      handle = double(cancel: true)
      temporal_client = double(workflow_handle: handle)
      agent_run.update!(temporal_workflow_id: "workflow-123")

      allow(Paid).to receive(:temporal_client).and_return(temporal_client)

      described_class.perform_now(agent_run.id)

      expect(temporal_client).to have_received(:workflow_handle).with("workflow-123")
      expect(handle).to have_received(:cancel)
    end

    it "ignores not-found Temporal workflow errors" do
      error = Temporalio::Error::RPCError.allocate
      allow(error).to receive(:code).and_return(Temporalio::Error::RPCError::Code::NOT_FOUND)
      agent_run.update!(temporal_workflow_id: "workflow-123")

      handle = double
      allow(handle).to receive(:cancel).and_raise(error)
      temporal_client = double(workflow_handle: handle)
      allow(Paid).to receive(:temporal_client).and_return(temporal_client)

      expect { described_class.perform_now(agent_run.id) }.not_to raise_error
    end

    it "cleans up the container when present" do
      agent_run.update!(container_id: "container-123")
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive(:cleanup_container)

      described_class.perform_now(agent_run.id)

      expect(agent_run).to have_received(:cleanup_container).with(force: true)
    end

    it "does not raise when agent run is not found" do
      expect { described_class.perform_now(-1) }.not_to raise_error
    end

    it "skips Temporal cancellation when no workflow id" do
      agent_run.update!(temporal_workflow_id: nil)
      allow(Paid).to receive(:temporal_client)

      described_class.perform_now(agent_run.id)

      expect(Paid).not_to have_received(:temporal_client)
    end
  end
end
