# frozen_string_literal: true

require "rails_helper"
require "rake"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "dev:cleanup" do
  let(:task) { Rake::Task["dev:cleanup"] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("dev:cleanup")
    task.reenable
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
end
# rubocop:enable RSpec/DescribeClass
