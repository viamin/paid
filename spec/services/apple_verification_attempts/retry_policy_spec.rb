# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::RetryPolicy do
  # @spec APPLE-ATTEMPT-010
  it "retries an infrastructure failure before the retry limit" do
    attempt = create(:apple_verification_attempt, :failed,
      failure_classification: "capacity_or_quota", retry_number: 0)

    result = described_class.call(attempt:)

    expect(result).to have_attributes(retryable: true, reason: "retryable infrastructure failure")
  end

  it "stops retrying an infrastructure failure at the retry limit" do
    attempt = create(:apple_verification_attempt, :failed,
      failure_classification: "capacity_or_quota",
      retry_number: AppleVerificationAttempts::Config.max_retries)

    result = described_class.call(attempt:)

    expect(result).to have_attributes(retryable: false, reason: "retry limit reached")
  end

  it "does not retry a deterministic project failure" do
    attempt = create(:apple_verification_attempt, :failed,
      failure_classification: "test_assertion")

    result = described_class.call(attempt:)

    expect(result).to have_attributes(retryable: false, reason: "deterministic project failure")
  end

  it "does not retry an attempt with no failure classification" do
    attempt = create(:apple_verification_attempt, :failed, failure_classification: nil)

    result = described_class.call(attempt:)

    expect(result).to have_attributes(retryable: false, reason: "no failure classification")
  end

  it "does not retry an attempt that is still active" do
    attempt = create(:apple_verification_attempt, status: "queued")

    result = described_class.call(attempt:)

    expect(result).to have_attributes(retryable: false, reason: "attempt is still active")
  end
end
