# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-010
RSpec.describe AppleVerificationAttempts::Rerun do
  context "when retrying classified failures" do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  it "permits an explicit rerun of a deterministic project failure" do
    attempt = create(
      :apple_verification_attempt,
      project:, account:, status: "failed", failure_classification: "test_assertion"
    )

    rerun_attempt = described_class.call(attempt:)

    expect(rerun_attempt).to have_attributes(status: "queued", retry_of_attempt: attempt)
    expect(project.apple_verification_attempts.count).to eq(2)
  end

  it "refuses a cancelled attempt without creating a retry" do
    attempt = create(
      :apple_verification_attempt,
      project:, account:, status: "cancelled", failure_classification: "worker_infrastructure"
    )

    expect { described_class.call(attempt:) }
      .to raise_error(ArgumentError, "attempt cannot be rerun: cancelled")
    expect(project.apple_verification_attempts.count).to eq(1)
  end

  it "refuses an attempt with an exhausted retry budget" do
    attempt = create(
      :apple_verification_attempt,
      project:, account:, status: "timed_out", failure_classification: "cancellation_or_timeout", retry_number: 3
    )

    expect { described_class.call(attempt:) }
      .to raise_error(ArgumentError, "attempt cannot be rerun: max_retries_exceeded")
    expect(project.apple_verification_attempts.count).to eq(1)
  end
end

  context "when preserving capture selection" do
  # @spec APPLE-VERIFY-006
  it "preserves a capture selection on the retry" do
    attempt = create(:apple_verification_attempt, status: "failed", requested_capture: "ios-app.initial-screen")

    rerun_attempt = described_class.call(attempt:)

    expect(rerun_attempt).to have_attributes(
      requested_capture: "ios-app.initial-screen",
      retry_of_attempt: attempt
    )
  end
end
end
