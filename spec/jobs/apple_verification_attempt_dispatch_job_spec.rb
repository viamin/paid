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
      "AppleVerificationWorkflow",
      { attempt_id: attempt.id },
      id: workflow_id,
      task_queue: Paid.agent_task_queue
    )
    expect(attempt.reload.temporal_workflow_id).to eq(workflow_id)
  end
end
