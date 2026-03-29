# frozen_string_literal: true

require "rails_helper"
require "rake"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "dev:cleanup" do
  let(:task) { Rake::Task["dev:cleanup"] }

  # Default grace period is now 300s for Temporal recovery. Tests in the
  # top-level context verify immediate-cleanup behavior, so force grace=0.
  around do |example|
    old_val = ENV["STARTUP_CLEANUP_GRACE_PERIOD"]
    ENV["STARTUP_CLEANUP_GRACE_PERIOD"] = "0"
    example.run
  ensure
    ENV["STARTUP_CLEANUP_GRACE_PERIOD"] = old_val
  end

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("dev:cleanup")
    task.reenable

    # Stub docker commands by default so tests don't hit real docker
    allow(DevCleanup).to receive(:find_orphaned_containers).and_return([])
    allow(DevCleanup).to receive(:mark_service_containers_stopped)
    allow(DevCleanup).to receive(:cleanup_stale_service_containers)
  end

  it "times out runs stuck in running" do
    running_run = create(:agent_run, :running)

    task.invoke

    running_run.reload
    expect(running_run.status).to eq("timeout")
    expect(running_run.error_message).to include("process was restarted")
    expect(running_run.completed_at).to be_present
  end

  it "times out runs stuck in pending" do
    pending_run = create(:agent_run, status: "pending")

    task.invoke

    pending_run.reload
    expect(pending_run.status).to eq("timeout")
    expect(pending_run.error_message).to include("process was restarted")
  end

  it "creates a system log entry on each resolved run" do
    running_run = create(:agent_run, :running)

    task.invoke

    log = running_run.agent_run_logs.last
    expect(log.log_type).to eq("system")
    expect(log.content).to include("startup cleanup")
  end

  it "updates the associated issue paid_state to failed" do
    running_run = create(:agent_run, :running)
    running_run.issue.update!(paid_state: "in_progress")

    task.invoke

    expect(running_run.issue.reload.paid_state).to eq("failed")
  end

  it "does not touch finished runs" do
    completed = create(:agent_run, :completed)
    failed = create(:agent_run, :failed)
    timed_out = create(:agent_run, :timeout)

    task.invoke

    expect(completed.reload.status).to eq("completed")
    expect(failed.reload.status).to eq("failed")
    expect(timed_out.reload.status).to eq("timeout")
  end

  it "does not touch queued runs" do
    queued_run = create(:agent_run, :queued)

    task.invoke

    expect(queued_run.reload.status).to eq("queued")
  end

  it "triggers ProcessRunQueueJob when runs are resolved" do
    create(:agent_run, :running)

    expect { task.invoke }.to have_enqueued_job(ProcessRunQueueJob)
  end

  it "triggers ProcessRunQueueJob when queued runs exist but no stale runs" do
    create(:agent_run, :queued)

    expect { task.invoke }.to have_enqueued_job(ProcessRunQueueJob)
  end

  it "does not trigger ProcessRunQueueJob when nothing needs processing" do
    expect { task.invoke }.not_to have_enqueued_job(ProcessRunQueueJob)
  end

  it "resolves multiple stale runs in a single pass" do
    running = create(:agent_run, :running)
    pending_run = create(:agent_run, status: "pending")

    task.invoke

    expect(running.reload.status).to eq("timeout")
    expect(pending_run.reload.status).to eq("timeout")
  end

  it "marks service containers as stopped when grace is zero and containers were found" do
    allow(DevCleanup).to receive(:find_orphaned_containers).and_return([ "abc123" ])
    allow(DevCleanup).to receive(:stop_containers)

    task.invoke

    expect(DevCleanup).to have_received(:stop_containers).with([ "abc123" ])
    expect(DevCleanup).to have_received(:mark_service_containers_stopped)
  end

  it "does not mark service containers as stopped when no orphaned containers exist" do
    task.invoke

    expect(DevCleanup).not_to have_received(:mark_service_containers_stopped)
  end

  it "stops orphaned agent containers" do
    allow(DevCleanup).to receive(:find_orphaned_containers).and_return([ "abc123" ])
    allow(DevCleanup).to receive(:stop_containers)

    task.invoke

    expect(DevCleanup).to have_received(:stop_containers).with([ "abc123" ])
  end

  it "does not call docker stop when no orphaned containers exist" do
    allow(DevCleanup).to receive(:stop_containers)

    task.invoke

    expect(DevCleanup).not_to have_received(:stop_containers)
  end

  context "with STARTUP_CLEANUP_GRACE_PERIOD set" do
    around do |example|
      old_val = ENV["STARTUP_CLEANUP_GRACE_PERIOD"]
      ENV["STARTUP_CLEANUP_GRACE_PERIOD"] = "1800"
      example.run
    ensure
      ENV["STARTUP_CLEANUP_GRACE_PERIOD"] = old_val
    end

    it "skips runs updated within the grace period" do
      recent_run = create(:agent_run, :running, updated_at: 10.minutes.ago)

      task.invoke

      expect(recent_run.reload.status).to eq("running")
    end

    it "times out runs older than the grace period" do
      old_run = create(:agent_run, :running, updated_at: 60.minutes.ago)

      task.invoke

      expect(old_run.reload.status).to eq("timeout")
    end

    it "only stops containers belonging to stale runs" do
      old_run = create(:agent_run, :running, updated_at: 60.minutes.ago, container_id: "stale-container")
      create(:agent_run, :running, updated_at: 10.minutes.ago, container_id: "recent-container")
      allow(DevCleanup).to receive(:stop_containers)

      task.invoke

      expect(old_run.reload.status).to eq("timeout")
      expect(DevCleanup).to have_received(:stop_containers).with([ "stale-container" ])
    end

    it "does not stop containers when only recent runs exist" do
      create(:agent_run, :running, updated_at: 10.minutes.ago, container_id: "recent-container")
      allow(DevCleanup).to receive(:stop_containers)

      task.invoke

      expect(DevCleanup).not_to have_received(:stop_containers)
    end

    it "does not scan for all labeled containers" do
      create(:agent_run, :running, updated_at: 60.minutes.ago)

      task.invoke

      expect(DevCleanup).not_to have_received(:find_orphaned_containers)
    end

    it "cleans up stale service containers via provisioner" do
      create(:agent_run, :running, updated_at: 60.minutes.ago)

      task.invoke

      expect(DevCleanup).to have_received(:cleanup_stale_service_containers)
    end

    it "deduplicates container IDs before stopping" do
      create(:agent_run, :running, updated_at: 60.minutes.ago, container_id: "same-container")
      create(:agent_run, :running, updated_at: 60.minutes.ago, container_id: "same-container")
      allow(DevCleanup).to receive(:stop_containers)

      task.invoke

      expect(DevCleanup).to have_received(:stop_containers).with([ "same-container" ])
    end
  end

  context "with invalid STARTUP_CLEANUP_GRACE_PERIOD" do
    around do |example|
      old_val = ENV["STARTUP_CLEANUP_GRACE_PERIOD"]
      ENV["STARTUP_CLEANUP_GRACE_PERIOD"] = "not_a_number"
      example.run
    ensure
      ENV["STARTUP_CLEANUP_GRACE_PERIOD"] = old_val
    end

    it "falls back to zero and times out all active runs" do
      running_run = create(:agent_run, :running)

      task.invoke

      expect(running_run.reload.status).to eq("timeout")
    end
  end

  context "with negative STARTUP_CLEANUP_GRACE_PERIOD" do
    around do |example|
      old_val = ENV["STARTUP_CLEANUP_GRACE_PERIOD"]
      ENV["STARTUP_CLEANUP_GRACE_PERIOD"] = "-300"
      example.run
    ensure
      ENV["STARTUP_CLEANUP_GRACE_PERIOD"] = old_val
    end

    it "clamps to zero and times out all active runs" do
      running_run = create(:agent_run, :running)

      task.invoke

      expect(running_run.reload.status).to eq("timeout")
    end
  end

  context "with default STARTUP_CLEANUP_GRACE_PERIOD (unset)" do
    around do |example|
      old_val = ENV.delete("STARTUP_CLEANUP_GRACE_PERIOD")
      example.run
    ensure
      ENV["STARTUP_CLEANUP_GRACE_PERIOD"] = old_val
    end

    it "preserves recent runs for Temporal recovery" do
      recent_run = create(:agent_run, :running, updated_at: 1.minute.ago)

      task.invoke

      expect(recent_run.reload.status).to eq("running")
    end

    it "times out runs older than the default grace period" do
      old_run = create(:agent_run, :running, updated_at: 10.minutes.ago)

      task.invoke

      expect(old_run.reload.status).to eq("timeout")
    end
  end
end
# rubocop:enable RSpec/DescribeClass
