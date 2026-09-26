# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Rerun do
  # @spec APPLE-VERIFY-006
  it "preserves a capture selection on the retry" do
    attempt = create(:apple_verification_attempt, status: "failed", failure_classification: "worker_infrastructure", requested_capture: "ios-app.initial-screen")

    rerun_attempt = described_class.call(attempt:)

    expect(rerun_attempt).to have_attributes(
      requested_capture: "ios-app.initial-screen",
      retry_of_attempt: attempt
    )
  end
end
