# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttemptDispatchJob, type: :job do
  it "starts a durable worker workflow and records its identifier" do # @spec APPLE-VERIFY-003
    attempt = create(:apple_verification_attempt)
    temporal_client = instance_double(Temporalio::Client, start_workflow: nil)
    allow(Paid).to receive(:temporal_client).and_return(temporal_client)

    described_class.perform_now(attempt.id)

    workflow_id = "apple-verification-attempt-#{attempt.id}"
    expect(temporal_client).to have_received(:start_workflow).with(
      Workflows::AppleVerificationWorkflow,
      { attempt_id: attempt.id },
      id: workflow_id,
      task_queue: Paid.agent_task_queue
    )
    expect(attempt.reload.temporal_workflow_id).to eq(workflow_id)
  end

  it "does not start a workflow for an attempt cancelled before dispatch" do # @spec APPLE-VERIFY-003
    attempt = create(:apple_verification_attempt, state: "cancelled")
    temporal_client = instance_double(Temporalio::Client, start_workflow: nil)
    allow(Paid).to receive(:temporal_client).and_return(temporal_client)

    described_class.perform_now(attempt.id)

    expect(temporal_client).not_to have_received(:start_workflow)
  end

  it "cancels a workflow started while the attempt lock is held" do # @spec APPLE-VERIFY-003
    attempt = create(:apple_verification_attempt)
    workflow_handle = instance_double(Temporalio::Client::WorkflowHandle, cancel: nil)
    temporal_client = instance_double(Temporalio::Client, workflow_handle: workflow_handle)
    allow(temporal_client).to receive(:start_workflow) { attempt.cancel! }
    allow(Paid).to receive(:temporal_client).and_return(temporal_client)

    described_class.perform_now(attempt.id)

    expect(workflow_handle).to have_received(:cancel)
    expect(attempt.reload).to be_cancelled
  end
end
