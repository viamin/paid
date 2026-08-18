# frozen_string_literal: true

require "rails_helper"

# @spec EXEC-DISABLE-006
RSpec.describe ExecutionControlParkCleanupJob, type: :job do
  describe "#perform" do
    let!(:agent_run) { create(:agent_run, :paused) }

    it "cancels the Temporal workflow when a workflow id is given" do
      handle = double(cancel: true)
      temporal_client = double(workflow_handle: handle)
      allow(Paid).to receive(:temporal_client).and_return(temporal_client)

      described_class.perform_now(agent_run.id, "workflow-123", nil)

      expect(temporal_client).to have_received(:workflow_handle).with("workflow-123")
      expect(handle).to have_received(:cancel)
    end

    it "skips Temporal cancellation when no workflow id is given" do
      allow(Paid).to receive(:temporal_client)

      described_class.perform_now(agent_run.id, nil, nil)

      expect(Paid).not_to have_received(:temporal_client)
    end

    it "skips the claimed-run sentinel instead of treating it as a real workflow id" do
      allow(Paid).to receive(:temporal_client)

      described_class.perform_now(agent_run.id, AgentRun::CLAIMED_SENTINEL, nil)

      expect(Paid).not_to have_received(:temporal_client)
    end

    it "ignores not-found Temporal workflow errors" do
      error = Temporalio::Error::RPCError.allocate
      allow(error).to receive(:code).and_return(Temporalio::Error::RPCError::Code::NOT_FOUND)

      handle = double
      allow(handle).to receive(:cancel).and_raise(error)
      temporal_client = double(workflow_handle: handle)
      allow(Paid).to receive(:temporal_client).and_return(temporal_client)

      expect { described_class.perform_now(agent_run.id, "workflow-123", nil) }.not_to raise_error
    end

    it "re-raises transient Temporal workflow errors for retry_on to handle" do
      error = Temporalio::Error::RPCError.allocate
      allow(error).to receive(:code).and_return(Temporalio::Error::RPCError::Code::UNAVAILABLE)

      handle = double
      allow(handle).to receive(:cancel).and_raise(error)
      temporal_client = double(workflow_handle: handle)
      allow(Paid).to receive(:temporal_client).and_return(temporal_client)

      expect { described_class.new.perform(agent_run.id, "workflow-123", nil) }.to raise_error(Temporalio::Error::RPCError)
    end

    it "cleans up the container when a container id is given" do
      container = double(id: "container-123")
      volume = double

      allow(container).to receive(:refresh!)
      allow(container).to receive(:info).and_return("State" => { "Running" => true })
      allow(container).to receive(:stop)
      allow(container).to receive(:delete)
      allow(Docker::Container).to receive(:get).with("container-123").and_return(container)
      allow(Docker::Volume).to receive(:get).with("paid-workspace-#{agent_run.id}").and_return(volume)
      allow(volume).to receive(:remove)

      described_class.perform_now(agent_run.id, nil, "container-123")

      expect(container).to have_received(:stop).with(timeout: 0)
      expect(container).to have_received(:delete).with(force: true, v: true)
      expect(volume).to have_received(:remove)
      expect(agent_run.reload.container_id).to be_nil
    end

    it "does not raise when the agent run is not found" do
      expect { described_class.perform_now(-1, nil, nil) }.not_to raise_error
    end
  end
end
