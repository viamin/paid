# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::AppleVerificationWorkflow, :no_db do
  it "starts the attempt through its registered activity" do # @spec APPLE-VERIFY-003
    workflow = described_class.new
    allow(workflow).to receive(:run_activity).and_return(status: :running, attempt_id: 12)

    result = workflow.execute(attempt_id: 12)

    expect(workflow).to have_received(:run_activity).with(
      Activities::StartAppleVerificationAttemptActivity,
      { attempt_id: 12 },
      timeout: 30
    )
    expect(result).to eq(status: :running, attempt_id: 12)
  end
end
