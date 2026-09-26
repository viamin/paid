# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Complete do
  # @spec APPLE-ATTEMPT-006
  it "records the terminal state and revokes credentials for a succeeded attempt" do
    attempt = create(:apple_verification_attempt, status: "running")
    revocation = instance_double(AppleVerification::Revocation::Enforce)
    allow(revocation).to receive(:call)

    described_class.call(attempt:, status: "succeeded", revocation:)

    expect(attempt.reload).to have_attributes(status: "succeeded", failure_classification: nil)
    expect(revocation).to have_received(:call)
  end

  it "skips the immediate VM destroy when no lifecycle is configured" do
    attempt = create(:apple_verification_attempt, status: "running")

    expect { described_class.call(attempt:, status: "succeeded") }
      .to change { attempt.reload.status }.from("running").to("succeeded")
  end

  it "still records the terminal state and revocation when the immediate destroy fails" do
    attempt = create(:apple_verification_attempt, status: "running")
    lifecycle = instance_double(AppleVerification::Lifecycle)
    allow(lifecycle).to receive(:destroy).and_raise(Faraday::ConnectionFailed.new("host down"))
    revocation = instance_double(AppleVerification::Revocation::Enforce)
    allow(revocation).to receive(:call)

    described_class.call(attempt:, status: "succeeded", lifecycle:, revocation:)

    expect(attempt.reload).to have_attributes(status: "succeeded")
    expect(revocation).to have_received(:call)
  end

  it "rejects an invalid failure classification" do
    attempt = create(:apple_verification_attempt, status: "running")

    expect { described_class.call(attempt:, status: "failed", failure_classification: "not_a_class") }
      .to raise_error(ArgumentError, /classification/)
  end
end
