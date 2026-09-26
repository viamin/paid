# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-010
RSpec.describe AppleVerificationAttempts::RetryPolicy do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:workflow) { create(:apple_verification_workflow_revision, project: project, account: account) }

  def attempt_with(status:, failure_classification: nil, retry_number: 0)
    create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: workflow,
      status: status,
      failure_classification: failure_classification,
      retry_number: retry_number
    )
  end

  it "permits retry of a capacity_or_quota timeout" do
    attempt = attempt_with(status: "timed_out", failure_classification: "cancellation_or_timeout")

    decision = described_class.call(attempt: attempt)

    expect(decision).to be_retryable
    expect(decision.classification).to eq("cancellation_or_timeout")
  end

  it "permits retry of a terminal attempt without a failure classification" do
    attempt = attempt_with(status: "failed")

    decision = described_class.call(attempt: attempt)

    expect(decision).to be_retryable
    expect(decision.classification).to be_nil
  end

  it "permits retry of a terminal attempt with an unknown failure classification" do
    attempt = attempt_with(status: "failed", failure_classification: "code_defect")

    decision = described_class.call(attempt: attempt)

    expect(decision).to be_retryable
    expect(decision.classification).to be_nil
  end

  it "permits retry of worker_infrastructure outcomes within the configured budget" do
    attempt = attempt_with(status: "failed", failure_classification: "worker_infrastructure", retry_number: 1)

    decision = described_class.call(attempt: attempt, max_retries: 3)

    expect(decision).to be_retryable
  end

  it "refuses to retry deterministic project failures" do
    attempt = attempt_with(status: "failed", failure_classification: "test_assertion")

    decision = described_class.call(attempt: attempt)

    expect(decision).not_to be_retryable
    expect(decision.reason).to eq("not_infrastructure")
  end

  it "refuses to retry cancelled attempts even when the classification would otherwise qualify" do
    attempt = attempt_with(status: "cancelled", failure_classification: "worker_infrastructure")

    decision = described_class.call(attempt: attempt)

    expect(decision).not_to be_retryable
    expect(decision.reason).to eq("cancelled")
  end

  it "refuses to retry once the retry budget is exhausted" do
    attempt = attempt_with(status: "timed_out", failure_classification: "cancellation_or_timeout", retry_number: 3)

    decision = described_class.call(attempt: attempt, max_retries: 3)

    expect(decision).not_to be_retryable
    expect(decision.reason).to eq("max_retries_exceeded")
  end

  it "refuses to retry an attempt that has not reached a terminal state" do
    attempt = attempt_with(status: "running")

    decision = described_class.call(attempt: attempt)

    expect(decision).not_to be_retryable
    expect(decision.reason).to eq("not_terminal")
  end

  describe ".explicit" do
    it "permits an administrator-initiated rerun of a deterministic project failure" do
      attempt = attempt_with(status: "failed", failure_classification: "test_assertion")

      decision = described_class.explicit(attempt: attempt)

      expect(decision).to be_retryable
      expect(decision.classification).to eq("test_assertion")
    end

    it "still refuses an administrator-initiated rerun of a cancelled attempt" do
      attempt = attempt_with(status: "cancelled", failure_classification: "worker_infrastructure")

      decision = described_class.explicit(attempt: attempt)

      expect(decision).not_to be_retryable
      expect(decision.reason).to eq("cancelled")
    end

    it "still refuses an administrator-initiated rerun once the retry budget is exhausted" do
      attempt = attempt_with(status: "timed_out", failure_classification: "cancellation_or_timeout", retry_number: 3)

      decision = described_class.explicit(attempt: attempt, max_retries: 3)

      expect(decision).not_to be_retryable
      expect(decision.reason).to eq("max_retries_exceeded")
    end
  end
end
