# frozen_string_literal: true

require "rails_helper"

RSpec.describe StaleRunDetectorJob do
  # agent_timeout + GRACE_PERIOD = total threshold before a run is considered stale
  let(:stale_threshold) { Rails.application.config.x.agent_timeout + described_class::GRACE_PERIOD.to_i }

  describe "#perform" do
    it "times out runs stuck in running beyond the threshold" do
      stale_run = create(:agent_run, :running, started_at: (stale_threshold + 60).seconds.ago)

      described_class.perform_now

      stale_run.reload
      expect(stale_run.status).to eq("timeout")
      expect(stale_run.error_message).to include("Stale run detected")
      expect(stale_run.completed_at).to be_present
    end

    it "times out runs stuck in pending beyond the threshold" do
      stale_run = create(:agent_run, status: "pending")
      stale_run.update_columns(updated_at: (stale_threshold + 60).seconds.ago)

      described_class.perform_now

      stale_run.reload
      expect(stale_run.status).to eq("timeout")
      expect(stale_run.error_message).to include("Stale run detected")
    end

    it "does not touch running runs within the threshold" do
      recent_run = create(:agent_run, :running, started_at: (stale_threshold - 60).seconds.ago)

      described_class.perform_now

      expect(recent_run.reload.status).to eq("running")
    end

    it "does not touch pending runs within the threshold" do
      recent_run = create(:agent_run, status: "pending")
      recent_run.update_columns(updated_at: (stale_threshold - 60).seconds.ago)

      described_class.perform_now

      expect(recent_run.reload.status).to eq("pending")
    end

    it "does not touch completed or failed runs" do
      create(:agent_run, :completed, started_at: 2.days.ago)
      create(:agent_run, :failed, started_at: 2.days.ago)

      expect { described_class.perform_now }.not_to change { AgentRun.where(status: "timeout").count }
    end

    it "updates the issue paid_state to failed" do
      stale_run = create(:agent_run, :running, started_at: (stale_threshold + 60).seconds.ago)
      stale_run.issue.update!(paid_state: "in_progress")

      described_class.perform_now

      expect(stale_run.issue.reload.paid_state).to eq("failed")
    end

    it "creates a log entry on the resolved run" do
      stale_run = create(:agent_run, :running, started_at: (stale_threshold + 60).seconds.ago)

      described_class.perform_now

      log = stale_run.agent_run_logs.last
      expect(log.content).to include("stale run detector")
    end

    it "triggers ProcessRunQueueJob when runs are resolved" do
      create(:agent_run, :running, started_at: (stale_threshold + 60).seconds.ago)

      expect { described_class.perform_now }.to have_enqueued_job(ProcessRunQueueJob)
    end

    it "does not trigger ProcessRunQueueJob when no runs are resolved" do
      expect { described_class.perform_now }.not_to have_enqueued_job(ProcessRunQueueJob)
    end

    it "resolves multiple stale runs in a single pass" do
      stale_run1 = create(:agent_run, :running, started_at: (stale_threshold + 120).seconds.ago)
      stale_run2 = create(:agent_run, :running, started_at: (stale_threshold + 60).seconds.ago)

      described_class.perform_now

      expect(stale_run1.reload.status).to eq("timeout")
      expect(stale_run2.reload.status).to eq("timeout")
    end

    it "calls cleanup_container when a run is timed out" do
      stale_run = create(:agent_run, :running, started_at: (stale_threshold + 60).seconds.ago,
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
      create(:agent_run, :running, started_at: (stale_threshold + 60).seconds.ago)
      provisioner = instance_double(Containers::ServiceProvisioner, cleanup: nil)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)

      described_class.perform_now

      expect(provisioner).to have_received(:cleanup)
    end

    it "still resolves the run when container cleanup fails" do
      stale_run = create(:agent_run, :running, started_at: (stale_threshold + 60).seconds.ago,
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
      stale_run = create(:agent_run, :running, started_at: (stale_threshold + 60).seconds.ago)
      allow(Containers::ServiceProvisioner).to receive(:new).and_raise(RuntimeError, "gone")

      described_class.perform_now

      expect(stale_run.reload.status).to eq("timeout")
    end
  end
end
