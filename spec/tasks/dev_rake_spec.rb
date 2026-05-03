# frozen_string_literal: true

require "rails_helper"
require "rake"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "dev:cleanup" do
  let(:task) { Rake::Task["dev:cleanup"] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("dev:cleanup")
    task.reenable

    allow(DevCleanup).to receive(:find_orphaned_containers).and_return([])
    allow(DevCleanup).to receive(:mark_service_containers_stopped)
  end

  around do |example|
    old_kill_all = ENV.delete("STARTUP_CLEANUP_KILL_ALL")
    SilenceStreams.call(:stdout, :stderr) { example.run }
  ensure
    ENV["STARTUP_CLEANUP_KILL_ALL"] = old_kill_all
  end

  it "does not touch active runs by default" do
    running_run = create(:agent_run, :running)
    queued_run = create(:agent_run, status: "queued")

    task.invoke

    expect(running_run.reload.status).to eq("running")
    expect(queued_run.reload.status).to eq("queued")
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

  it "triggers ProcessRunQueueJob when queued runs exist" do
    create(:agent_run, :queued)

    expect { task.invoke }.to have_enqueued_job(ProcessRunQueueJob)
  end

  it "does not trigger ProcessRunQueueJob when nothing needs processing" do
    expect { task.invoke }.not_to have_enqueued_job(ProcessRunQueueJob)
  end

  it "does not trigger ProcessRunQueueJob when only active (non-queued) runs exist" do
    create(:agent_run, :running)

    expect { task.invoke }.not_to have_enqueued_job(ProcessRunQueueJob)
  end

  context "with STARTUP_CLEANUP_KILL_ALL=1" do
    around do |example|
      old_val = ENV["STARTUP_CLEANUP_KILL_ALL"]
      ENV["STARTUP_CLEANUP_KILL_ALL"] = "1"
      example.run
    ensure
      ENV["STARTUP_CLEANUP_KILL_ALL"] = old_val
    end

    it "times out runs stuck in running" do
      running_run = create(:agent_run, :running)

      task.invoke

      running_run.reload
      expect(running_run.status).to eq("timeout")
      expect(running_run.error_message).to include("process was restarted")
      expect(running_run.completed_at).to be_present
    end

    it "times out runs stuck as stale claimed" do
      stale_claimed = create(:agent_run, status: "queued", temporal_workflow_id: "test-wf")
      stale_claimed.update_column(:updated_at, AgentRun.stale_claimed_cutoff - 1.minute)

      task.invoke

      stale_claimed.reload
      expect(stale_claimed.status).to eq("timeout")
      expect(stale_claimed.error_message).to include("process was restarted")
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

    it "resolves multiple stale runs in a single pass" do
      running = create(:agent_run, :running)
      stale_claimed = create(:agent_run, status: "queued", temporal_workflow_id: "test-wf")
      stale_claimed.update_column(:updated_at, AgentRun.stale_claimed_cutoff - 1.minute)

      task.invoke

      expect(running.reload.status).to eq("timeout")
      expect(stale_claimed.reload.status).to eq("timeout")
    end

    it "triggers ProcessRunQueueJob when queued runs exist alongside resolved runs" do
      create(:agent_run, :running)
      create(:agent_run, :queued)

      expect { task.invoke }.to have_enqueued_job(ProcessRunQueueJob)
    end

    it "does not trigger ProcessRunQueueJob when only active runs are resolved" do
      create(:agent_run, :running)

      expect { task.invoke }.not_to have_enqueued_job(ProcessRunQueueJob)
    end

    it "marks service containers as stopped when orphaned containers were found" do
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
  end
end
# rubocop:enable RSpec/DescribeClass
