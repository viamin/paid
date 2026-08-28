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

    it "tears down the stale container without clobbering a container_id the run picked up via redispatch" do
      # Simulates the control being cleared and the run re-dispatched to a
      # new container while this job's teardown of the OLD container was
      # still pending/retrying.
      agent_run.update!(status: "queued", paused_at: nil, container_id: "new-container-456")

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

      expect(container).to have_received(:delete)
      expect(agent_run.reload.container_id).to eq("new-container-456")
    end

    it "reconstructs the runner handle for runner-backed runs so cleanup takes the runner path" do
      handle_hash = ExecutionRunners::RunnerHandle.new(
        runner_type: :contract,
        identifier: "container-123",
        host: "contract",
        workspace_ref: "contract-#{agent_run.id}",
        metadata: { "agent_run_id" => agent_run.id }
      ).to_storage

      runner = instance_double(ExecutionRunners::ContractRunner)
      allow(ExecutionRunners).to receive(:resolve_for).and_return(runner)
      allow(runner).to receive(:cleanup)

      described_class.perform_now(agent_run.id, nil, "container-123", handle_hash)

      expect(runner).to have_received(:cleanup).with(
        handle: an_instance_of(ExecutionRunners::RunnerHandle),
        force: true
      )
    end

    it "cleans up runner-backed runs even when only the persisted handle snapshot is available" do
      handle_hash = ExecutionRunners::RunnerHandle.new(
        runner_type: :contract,
        identifier: "runner-environment-123",
        host: "contract",
        workspace_ref: "contract-#{agent_run.id}",
        metadata: { "agent_run_id" => agent_run.id }
      ).to_storage

      runner = instance_double(ExecutionRunners::ContractRunner)
      allow(ExecutionRunners).to receive(:resolve_for).and_return(runner)
      allow(runner).to receive(:cleanup)

      described_class.perform_now(agent_run.id, nil, nil, handle_hash)

      expect(runner).to have_received(:cleanup).with(
        handle: an_object_having_attributes(identifier: "runner-environment-123"),
        force: true
      )
    end

    it "uses the park-time handle snapshot rather than the row's current runner_handle" do
      # If the run was resumed and re-dispatched to a new environment before
      # this job runs, agent_run.runner_handle on the row reflects the NEW
      # environment. The job must tear down the OLD (parked) handle passed in
      # as an argument, not whatever is currently persisted on the row.
      FeatureFlags.enable!(:execution_runner_enabled, project: agent_run.project)
      base_handle = { "runner_type" => "contract", "host" => "contract", "workspace_ref" => "contract-ref", "metadata" => {} }
      parked_handle_hash = base_handle.merge("identifier" => "container-123")
      redispatched_handle_hash = base_handle.merge("identifier" => "new-container-456")
      agent_run.update!(status: "queued", paused_at: nil, runner_handle: redispatched_handle_hash)

      runner = instance_double(ExecutionRunners::ContractRunner)
      allow(ExecutionRunners).to receive(:resolve_for).and_return(runner)
      allow(runner).to receive(:cleanup)

      described_class.perform_now(agent_run.id, nil, "container-123", parked_handle_hash)

      expect(runner).to have_received(:cleanup).with(
        handle: an_object_having_attributes(identifier: "container-123"),
        force: true
      )
    end

    it "preserves the shared workspace volume when the run has been redispatched to a new container" do
      # A re-dispatched container for the same run reuses the
      # "paid-workspace-<agent_run.id>" volume, so tearing down the stale
      # container must not delete it out from under the active run.
      agent_run.update!(status: "queued", paused_at: nil, container_id: "new-container-456")

      container = double(id: "container-123")
      allow(container).to receive(:refresh!)
      allow(container).to receive(:info).and_return("State" => { "Running" => true })
      allow(container).to receive(:stop)
      allow(container).to receive(:delete)
      allow(Docker::Container).to receive(:get).with("container-123").and_return(container)
      allow(Docker::Volume).to receive(:get)

      described_class.perform_now(agent_run.id, nil, "container-123")

      expect(container).to have_received(:delete)
      expect(Docker::Volume).not_to have_received(:get)
    end
  end
end
