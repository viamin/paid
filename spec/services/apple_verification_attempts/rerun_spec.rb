# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-010
RSpec.describe AppleVerificationAttempts::Rerun do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  it "refuses a deterministic failure without creating a retry" do
    attempt = create(
      :apple_verification_attempt,
      project:, account:, status: "failed", failure_classification: "test_assertion"
    )

    expect { described_class.call(attempt:) }
      .to raise_error(ArgumentError, "attempt cannot be rerun: not_infrastructure")
    expect(project.apple_verification_attempts.count).to eq(1)
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
