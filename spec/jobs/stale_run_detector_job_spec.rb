# frozen_string_literal: true

require "rails_helper"

RSpec.describe StaleRunDetectorJob do
  # Running runs: agent_timeout + GRACE_PERIOD
  let(:running_threshold) { AGENT_TIMEOUT_DEFAULT + described_class::GRACE_PERIOD.to_i }
  # Pending runs: shorter dedicated threshold
  let(:pending_threshold) { described_class::PENDING_TIMEOUT.to_i }

  describe "#perform" do
    it "times out runs stuck in running beyond the threshold" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)

      described_class.perform_now

      stale_run.reload
      expect(stale_run.status).to eq("timeout")
      expect(stale_run.error_message).to include("Stale run detected")
      expect(stale_run.completed_at).to be_present
    end

    it "does not touch running runs within the threshold" do
      recent_run = create(:agent_run, :running, started_at: (running_threshold - 60).seconds.ago)

      described_class.perform_now

      expect(recent_run.reload.status).to eq("running")
    end

    it "does not touch completed or failed runs" do
      create(:agent_run, :completed, started_at: 2.days.ago)
      create(:agent_run, :failed, started_at: 2.days.ago)

      expect { described_class.perform_now }.not_to change { AgentRun.where(status: "timeout").count }
    end

    it "updates the issue paid_state to failed" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)
      stale_run.issue.update!(paid_state: "in_progress")

      described_class.perform_now

      expect(stale_run.issue.reload.paid_state).to eq("failed")
    end

    it "creates a log entry on the resolved run" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)

      described_class.perform_now

      log = stale_run.agent_run_logs.last
      expect(log.content).to include("stale run detector")
    end

    it "triggers ProcessRunQueueJob when runs are resolved" do
      create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)

      expect { described_class.perform_now }.to have_enqueued_job(ProcessRunQueueJob)
    end

    it "does not trigger ProcessRunQueueJob when no runs are resolved" do
      expect { described_class.perform_now }.not_to have_enqueued_job(ProcessRunQueueJob)
    end

    it "resolves multiple stale runs in a single pass" do
      stale_run1 = create(:agent_run, :running, started_at: (running_threshold + 120).seconds.ago)
      stale_run2 = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)

      described_class.perform_now

      expect(stale_run1.reload.status).to eq("timeout")
      expect(stale_run2.reload.status).to eq("timeout")
    end

    it "calls cleanup_container when a run is timed out" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago,
        container_id: "dead-container-123")
      container_service = instance_double(Containers::Provision, cleanup: true)
      allow(Containers::Provision).to receive(:reconnect).and_return(container_service)
      allow(Containers::ServiceProvisioner).to receive(:new)
        .and_return(instance_double(Containers::ServiceProvisioner, cleanup: nil))

      described_class.perform_now

      expect(container_service).to have_received(:cleanup).with(force: true)
      expect(stale_run.reload.container_id).to be_nil
    end

    it "calls ServiceProvisioner#cleanup when a run is timed out" do
      create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)
      provisioner = instance_double(Containers::ServiceProvisioner, cleanup: nil)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)

      described_class.perform_now

      expect(provisioner).to have_received(:cleanup)
    end

    it "still resolves the run when container cleanup fails" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago,
        container_id: "dead-container-456")
      allow(Containers::Provision).to receive(:reconnect)
        .and_raise(Containers::Provision::ProvisionError, "gone")
      allow(Docker::Volume).to receive(:get)
        .and_raise(Docker::Error::NotFoundError, "no such volume")
      provisioner = instance_double(Containers::ServiceProvisioner, cleanup: nil)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)

      described_class.perform_now

      expect(stale_run.reload.status).to eq("timeout")
      expect(provisioner).to have_received(:cleanup)
    end

    it "still resolves the run when service cleanup fails" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)
      allow(Containers::ServiceProvisioner).to receive(:new).and_raise(RuntimeError, "gone")

      described_class.perform_now

      expect(stale_run.reload.status).to eq("timeout")
    end

    context "with stale pending runs" do
      it "requeues a stale pending run that has not exhausted requeue budget" do
        stale_run = create(:agent_run, status: "pending")
        stale_run.update_columns(updated_at: (pending_threshold + 60).seconds.ago)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.stale_requeue_count).to eq(1)
      end

      it "creates a log entry when requeuing" do
        stale_run = create(:agent_run, status: "pending")
        stale_run.update_columns(updated_at: (pending_threshold + 60).seconds.ago)

        described_class.perform_now

        log = stale_run.agent_run_logs.last
        expect(log.content).to include("requeued")
        expect(log.content).to include("attempt 1/#{described_class::MAX_STALE_REQUEUES}")
      end

      it "triggers ProcessRunQueueJob when runs are requeued" do
        stale_run = create(:agent_run, status: "pending")
        stale_run.update_columns(updated_at: (pending_threshold + 60).seconds.ago)

        expect { described_class.perform_now }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "times out a stale pending run that has exhausted requeue budget" do
        stale_run = create(:agent_run, status: "pending", stale_requeue_count: described_class::MAX_STALE_REQUEUES)
        stale_run.update_columns(updated_at: (pending_threshold + 60).seconds.ago)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("timeout")
        expect(stale_run.error_message).to include("Stale run detected")
      end

      it "does not touch pending runs within the threshold" do
        recent_run = create(:agent_run, status: "pending")
        recent_run.update_columns(updated_at: (pending_threshold - 60).seconds.ago)

        described_class.perform_now

        expect(recent_run.reload.status).to eq("pending")
      end

      it "cleans up docker resources when requeuing" do
        stale_run = create(:agent_run, status: "pending", container_id: "orphaned-container")
        stale_run.update_columns(updated_at: (pending_threshold + 60).seconds.ago)
        container_service = instance_double(Containers::Provision, cleanup: true)
        allow(Containers::Provision).to receive(:reconnect).and_return(container_service)
        allow(Containers::ServiceProvisioner).to receive(:new)
          .and_return(instance_double(Containers::ServiceProvisioner, cleanup: nil))

        described_class.perform_now

        expect(container_service).to have_received(:cleanup).with(force: true)
      end

      it "skips a run that transitioned out of pending before requeue" do
        # Simulate the race: run was pending at query time but transitions
        # to running before the lock is acquired inside requeue_stale_pending_run.
        run = create(:agent_run, status: "pending")
        run.update_columns(updated_at: (pending_threshold + 60).seconds.ago)
        # Transition to running before requeue_stale_pending_run acquires the lock
        run.update_columns(status: "running", started_at: Time.current, updated_at: Time.current)

        job = described_class.new
        result = job.send(:requeue_stale_pending_run, run)

        expect(result).to eq(:skip)
        expect(run.reload.status).to eq("running")
      end

      it "skips a pending run that was recently updated (no longer stale)" do
        # Run is still pending but was updated after the staleness query
        run = create(:agent_run, status: "pending")
        run.update_columns(updated_at: 1.minute.ago)

        job = described_class.new
        result = job.send(:requeue_stale_pending_run, run)

        expect(result).to eq(:skip)
        expect(run.reload.status).to eq("pending")
      end

      it "does not requeue a pending run just inside the threshold boundary" do
        # A run updated slightly less than PENDING_TIMEOUT ago is not stale
        boundary_run = create(:agent_run, status: "pending")
        boundary_run.update_columns(updated_at: (pending_threshold - 5).seconds.ago)

        described_class.perform_now

        expect(boundary_run.reload.status).to eq("pending")
      end

      it "increments requeue count on successive requeues" do
        stale_run = create(:agent_run, status: "pending", stale_requeue_count: 1)
        stale_run.update_columns(updated_at: (pending_threshold + 60).seconds.ago)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.stale_requeue_count).to eq(2)
      end

      it "cancels the existing Temporal workflow before requeuing" do
        stale_run = create(:agent_run, status: "pending",
          temporal_workflow_id: "queued-1-2-123456",
          temporal_run_id: "run-abc")
        stale_run.update_columns(updated_at: (pending_threshold + 60).seconds.ago)

        handle = double(cancel: true) # rubocop:disable RSpec/VerifiedDoubles
        temporal_client = double(workflow_handle: handle) # rubocop:disable RSpec/VerifiedDoubles
        allow(Paid).to receive(:temporal_client).and_return(temporal_client)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.temporal_workflow_id).to be_nil
        expect(stale_run.temporal_run_id).to be_nil
        expect(handle).to have_received(:cancel)
      end

      it "still requeues when Temporal workflow cancel fails with not-found" do
        stale_run = create(:agent_run, status: "pending", temporal_workflow_id: "queued-1-2-123456")
        stale_run.update_columns(updated_at: (pending_threshold + 60).seconds.ago)

        error = Temporalio::Error::RPCError.allocate
        allow(error).to receive(:code).and_return(Temporalio::Error::RPCError::Code::NOT_FOUND)
        handle = double # rubocop:disable RSpec/VerifiedDoubles
        allow(handle).to receive(:cancel).and_raise(error)
        temporal_client = double(workflow_handle: handle) # rubocop:disable RSpec/VerifiedDoubles
        allow(Paid).to receive(:temporal_client).and_return(temporal_client)

        described_class.perform_now

        expect(stale_run.reload.status).to eq("queued")
      end
    end
  end
end
