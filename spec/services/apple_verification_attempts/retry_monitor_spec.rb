# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::RetryMonitor do
  # @spec APPLE-ATTEMPT-010

  it "re-enqueues an unavailable worker-infrastructure attempt" do
    original = create(
      :apple_verification_attempt,
      status: "unavailable",
      failure_classification: "worker_infrastructure"
    )

    result = described_class.call

    expect(result.retried).to eq(1)
    expect(result.scanned).to eq(1)

    retry_attempt = AppleVerificationAttempt.find_by(retry_of_attempt: original)
    expect(retry_attempt).to be_present
    expect(retry_attempt.status).to eq("queued")
    expect(retry_attempt.retry_number).to eq(1)
  end

  it "does not re-enqueue a deterministic project failure" do
    create(:apple_verification_attempt, status: "failed", failure_classification: "test_assertion")

    result = described_class.call

    expect(result.retried).to eq(0)
    expect(AppleVerificationAttempt.where(status: "queued")).to be_empty
  end

  it "stops at the retry limit" do
    create(
      :apple_verification_attempt,
      status: "unavailable",
      failure_classification: "worker_infrastructure",
      retry_number: AppleVerificationAttempts::Config.max_retries
    )

    result = described_class.call

    expect(result.retried).to eq(0)
    expect(result.scanned).to eq(1)
    expect(AppleVerificationAttempt.where(status: "queued")).to be_empty
  end

  it "does not re-enqueue when the queue is already full" do
    create(:apple_verification_attempt, status: "unavailable", failure_classification: "worker_infrastructure")
    allow(AppleVerificationAttempts::Queue).to receive(:full?).and_return(true)

    result = described_class.call

    expect(result.retried).to eq(0)
    expect(result.scanned).to eq(0)
    expect(AppleVerificationAttempt.where(status: "queued")).to be_empty
  end

  it "does not scan an attempt that already has a retry" do
    original = create(:apple_verification_attempt, status: "unavailable", failure_classification: "worker_infrastructure")
    create(:apple_verification_attempt, retry_of_attempt: original)

    result = described_class.call

    expect(result.retried).to eq(0)
    expect(result.scanned).to eq(0)
    expect(AppleVerificationAttempt.where(status: "queued").count).to eq(1)
  end
end
