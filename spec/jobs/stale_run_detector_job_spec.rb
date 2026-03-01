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
      stale_run = create(:agent_run, status: "pending", created_at: (stale_threshold + 60).seconds.ago)

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
      recent_run = create(:agent_run, status: "pending", created_at: (stale_threshold - 60).seconds.ago)

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
  end
end
