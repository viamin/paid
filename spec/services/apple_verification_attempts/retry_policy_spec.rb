# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::RetryPolicy do
  # @spec APPLE-ATTEMPT-010
  it "retries bounded infrastructure failures but not deterministic failures" do
    infrastructure = create(:apple_verification_attempt, status: "failed", failure_classification: "worker_infrastructure")
    deterministic = create(:apple_verification_attempt, status: "failed", failure_classification: "test_assertion")

    expect(described_class).to be_retryable(infrastructure)
    expect(described_class).not_to be_retryable(deterministic)
  end
end
