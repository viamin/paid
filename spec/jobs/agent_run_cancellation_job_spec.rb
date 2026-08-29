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

    it "re-raises transient Temporal workflow errors for retry_on to handle" do
      error = Temporalio::Error::RPCError.allocate
      allow(error).to receive(:code).and_return(Temporalio::Error::RPCError::Code::UNAVAILABLE)
      agent_run.update!(temporal_workflow_id: "workflow-123")

      handle = double
      allow(handle).to receive(:cancel).and_raise(error)
      temporal_client = double(workflow_handle: handle)
      allow(Paid).to receive(:temporal_client).and_return(temporal_client)

      expect { described_class.new.perform(agent_run.id) }.to raise_error(Temporalio::Error::RPCError)
    end

    it "cleans up the container when present" do
      agent_run.update!(container_id: "container-123")
      container = double(id: "container-123")
      volume = double

      allow(container).to receive(:refresh!)
      allow(container).to receive(:info).and_return("State" => { "Running" => true })
      allow(container).to receive(:stop)
      allow(container).to receive(:delete)
      allow(Docker::Container).to receive(:get).with("container-123").and_return(container)
      allow(Docker::Volume).to receive(:get).with("paid-workspace-#{agent_run.id}").and_return(volume)
      allow(volume).to receive(:remove)

      described_class.perform_now(agent_run.id)

      expect(container).to have_received(:stop).with(timeout: 0)
      expect(container).to have_received(:delete).with(force: true, v: true)
      expect(volume).to have_received(:remove)
      expect(agent_run.reload.container_id).to be_nil
    end

    it "clears the container reference when the container is already missing" do
      agent_run.update!(container_id: "container-123")
      allow(Docker::Container).to receive(:get)
        .with("container-123")
        .and_raise(Docker::Error::NotFoundError, "not found")
      allow(Docker::Volume).to receive(:get)
        .with("paid-workspace-#{agent_run.id}")
        .and_raise(Docker::Error::NotFoundError, "not found")

      expect { described_class.perform_now(agent_run.id) }.not_to raise_error

      expect(agent_run.reload.container_id).to be_nil
    end

    it "rehydrates the persisted runner_handle before cleanup even after the runner flag is disabled" do
      handle = ExecutionRunners::RunnerHandle.new(
        runner_type: :local_docker,
        identifier: "runner-container-123",
        host: "local",
        workspace_ref: "paid-workspace-#{agent_run.id}",
        metadata: { "agent_run_id" => agent_run.id, "worktree_path" => nil, "environment" => {} }
      )
      agent_run.update!(container_id: nil, container_host: nil, runner_handle: handle.to_storage)
      runner = instance_double(ExecutionRunners::LocalDockerRunner, cleanup: nil)
      allow(ExecutionRunners).to receive(:resolve_for).with(instance_of(AgentRun)).and_return(runner)

      described_class.perform_now(agent_run.id)

      expect(runner).to have_received(:cleanup).with(handle: handle, force: true)
      reloaded = agent_run.reload
      expect(reloaded.container_id).to be_nil
      expect(reloaded.container_host).to be_nil
      expect(reloaded.runner_handle).to be_nil
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
