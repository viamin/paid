# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ParkSourceClosureRecoveryActivity do
  include ActiveJob::TestHelper

  let(:agent_run) do
    create(:agent_run, :running, branch_name: "agent/recovery",
      result_commit_sha: "a" * 40)
  end

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    example.run
  ensure
    clear_enqueued_jobs
    ActiveJob::Base.queue_adapter = original_adapter
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "leaves deterministic branch mismatches for manual retry" do
    expect {
      described_class.new.execute(
        agent_run_id: agent_run.id, category: "branch_mismatch", attempts: 3, auto_retry: false
      )
    }.not_to have_enqueued_job(SourceClosureRecoveryJob)

    expect(agent_run.reload).to be_waiting_recovery
  end

  # @spec PARTIAL-CLOSEOUT-044
  it "automatically retries recoverable assessment failures" do
    expect {
      described_class.new.execute(agent_run_id: agent_run.id, category: "transport_error", attempts: 3)
    }.to have_enqueued_job(SourceClosureRecoveryJob).with(agent_run.id)
  end
end
