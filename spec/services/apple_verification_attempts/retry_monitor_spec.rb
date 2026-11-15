# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::RetryMonitor do
  # @spec APPLE-ATTEMPT-010 AGENT-RETRY-018

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
    expect(retry_attempt.source_digest).to eq(original.source_digest)
    expect(retry_attempt.apple_verification_workflow_revision).to eq(original.apple_verification_workflow_revision)
  end

  it "excludes a deterministic project failure from the scan" do
    create(:apple_verification_attempt, status: "failed", failure_classification: "test_assertion")

    result = described_class.call

    expect(result.retried).to eq(0)
    expect(result.scanned).to eq(0)
    expect(result.reasons).to be_empty
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
    expect(result.reasons).to contain_exactly("retry limit reached")
    expect(result.reasons).to all(be_a(String))
    expect(AppleVerificationAttempt.where(status: "queued")).to be_empty
  end

  it "does not re-enqueue when the queue is already full" do
    create(:apple_verification_attempt, status: "unavailable", failure_classification: "worker_infrastructure")
    allow(AppleVerificationAttempts::Queue).to receive(:full?).and_return(true)

    result = described_class.call

    expect(result.retried).to eq(0)
    expect(result.scanned).to eq(0)
    expect(result.reasons).to contain_exactly("Apple verification queue is full")
    expect(result.reasons).to all(be_a(String))
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

  it "creates one successor across duplicate monitor passes" do # @spec AGENT-RETRY-005 AGENT-RETRY-006
    original = create(:apple_verification_attempt, status: "unavailable", failure_classification: "worker_infrastructure")

    2.times { described_class.call }

    expect(AppleVerificationAttempt.where(retry_of_attempt: original).count).to eq(1)
  end
end
