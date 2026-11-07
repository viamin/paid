# frozen_string_literal: true

require "rails_helper"
require "temporalio/client"

RSpec.describe SourceClosureRecoveryJob do
  let(:client) { instance_double(Temporalio::Client) }
  let(:run) { create(:agent_run, status: "running", branch_name: "paid/4886", result_commit_sha: "a" * 40) }

  before do
    PartialCloseouts::SourceClosureRecovery.park!(agent_run: run, category: "timeout", attempts: 3)
    allow(Paid).to receive(:temporal_client).and_return(client)
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "starts recovery with the claimed revision metadata" do
    allow(client).to receive(:start_workflow)

    described_class.perform_now(run.id)

    expect(client).to have_received(:start_workflow).with(
      Workflows::SourceClosureRecoveryWorkflow,
      { agent_run_id: run.id, project_id: run.project_id, recovery_attempt: 1, goal: run.goal,
        commit_sha: "a" * 40 },
      id: "source-closure-recovery-#{run.id}-1", task_queue: Paid.agent_task_queue
    )
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "releases its claim when Temporal cannot start the workflow" do
    error = Temporalio::Error::RPCError.new(
      "unavailable", code: Temporalio::Error::RPCError::Code::UNAVAILABLE, raw_grpc_status: nil
    )
    allow(client).to receive(:start_workflow).and_raise(error)

    expect {
      described_class.perform_now(run.id)
    }.to have_enqueued_job(described_class).with(run.id).and raise_error(Temporalio::Error::RPCError)
    expect(run.reload.reconciliation.dig("source_closure_recovery", "claimed_at")).to be_nil
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "releases the persisted claim when loading its attempt fails" do
    reloads = 0
    allow(AgentRun).to receive(:find_by).and_return(run)
    allow(run).to receive(:reload).and_wrap_original do |original|
      reloads += 1
      raise ActiveRecord::ConnectionNotEstablished, "connection lost" if reloads == 2

      original.call
    end

    expect { described_class.perform_now(run.id) }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    expect(run.reload.reconciliation.dig("source_closure_recovery", "claimed_at")).to be_nil
  end
end
