# frozen_string_literal: true

require "rails_helper"
require "temporalio/client"

# @spec PARTIAL-CLOSEOUT-045
RSpec.describe SourceClosureRecoveryJob do
  let(:client) { instance_double(Temporalio::Client) }
  let(:handle) { instance_double(Temporalio::Client::WorkflowHandle) }
  let(:status) { Temporalio::Client::WorkflowExecutionStatus::RUNNING }
  let(:description) { instance_double(Temporalio::Client::WorkflowExecution::Description, status:) }
  let(:project) { create(:project, auto_pick_enabled: true) }
  let(:run) { create(:agent_run, project:, status: "running", branch_name: "paid/4886", result_commit_sha: "a" * 40) }

  before do
    PartialCloseouts::SourceClosureRecovery.park!(agent_run: run, category: "timeout", attempts: 3)
    PartialCloseouts::SourceClosureRecovery.claim!(agent_run: run, now: 11.minutes.ago)
    allow(Paid).to receive(:temporal_client).and_return(client)
    allow(client).to receive_messages(workflow_handle: handle, start_workflow: nil)
    allow(handle).to receive(:describe).and_return(description)
  end

  def rpc_error(code)
    Temporalio::Error::RPCError.new("status unavailable", code:, raw_grpc_status: nil)
  end

  it "preserves a running execution and bounds its status RPC" do
    described_class.perform_now(run.id)

    expect(handle).to have_received(:describe).with(rpc_options: have_attributes(timeout: 5, override_retry: false))
    expect(client).not_to have_received(:start_workflow)
    expect(run.reload.reconciliation.dig("source_closure_recovery", "recovery_attempt")).to eq(1)
  end

  it "permits a successor after the previous execution completed" do
    allow(description).to receive(:status).and_return(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)

    described_class.perform_now(run.id)

    expect(client).to have_received(:start_workflow).with(anything, anything,
      id: "source-closure-recovery-#{run.id}-2", task_queue: Paid.agent_task_queue)
  end

  it "permits recovery after a crash before the previous workflow started" do
    allow(handle).to receive(:describe).and_raise(rpc_error(Temporalio::Error::RPCError::Code::NOT_FOUND))

    described_class.perform_now(run.id)

    expect(client).to have_received(:workflow_handle).with("source-closure-recovery-#{run.id}-1")
    expect(client).to have_received(:start_workflow).once
    expect(run.reload.reconciliation.dig("source_closure_recovery", "recovery_attempt")).to eq(2)
  end

  it "defers unavailable status without clearing another attempt's claim" do
    before_state = run.reload.reconciliation.deep_dup
    allow(handle).to receive(:describe).and_raise(rpc_error(Temporalio::Error::RPCError::Code::UNAVAILABLE))

    expect { described_class.perform_now(run.id) }.to have_enqueued_job(described_class).with(run.id)

    expect(client).not_to have_received(:start_workflow)
    expect(run.reload.reconciliation).to eq(before_state)
  end

  it "fails closed for an unknown execution status" do
    allow(description).to receive(:status).and_return(0)

    expect { described_class.perform_now(run.id) }.to have_enqueued_job(described_class).with(run.id)

    expect(client).not_to have_received(:start_workflow)
    expect(run.reload.reconciliation.dig("source_closure_recovery", "recovery_attempt")).to eq(1)
  end

  it "does not release another attempt's claim when status lookup fails unexpectedly" do
    before_state = run.reload.reconciliation.deep_dup
    allow(handle).to receive(:describe).and_raise(IOError, "connection lost")

    expect { described_class.perform_now(run.id) }.to raise_error(IOError)

    expect(client).not_to have_received(:start_workflow)
    expect(run.reload.reconciliation).to eq(before_state)
  end

  it "retains the durable execution when the server accepted a start but its reply was lost" do
    allow(description).to receive(:status).and_return(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
    allow(client).to receive(:start_workflow) do
      allow(description).to receive(:status).and_return(Temporalio::Client::WorkflowExecutionStatus::RUNNING)
      raise rpc_error(Temporalio::Error::RPCError::Code::UNAVAILABLE)
    end
    expect { described_class.perform_now(run.id) }.to raise_error(Temporalio::Error::RPCError)

    described_class.perform_now(run.id)

    expect(client).to have_received(:workflow_handle).with("source-closure-recovery-#{run.id}-2")
    expect(client).to have_received(:start_workflow).once
    expect(run.reload.reconciliation.dig("source_closure_recovery", "recovery_attempt")).to eq(2)
  end

  it "does not use a prior execution's status after another attempt takes ownership" do
    allow(description).to receive(:status).and_return(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
    allow(handle).to receive(:describe) do
      state = run.reload.reconciliation
      state["source_closure_recovery"].merge!("recovery_attempt" => 2, "claimed_at" => 11.minutes.ago.iso8601)
      run.update!(reconciliation: state)
      description
    end

    described_class.perform_now(run.id)

    expect(client).not_to have_received(:start_workflow)
    expect(run.reload.reconciliation.dig("source_closure_recovery", "recovery_attempt")).to eq(2)
  end
end
