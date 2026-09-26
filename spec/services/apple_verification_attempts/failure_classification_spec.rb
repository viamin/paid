# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::FailureClassification do
  # @spec APPLE-ATTEMPT-009
  it "accepts only classifications from the closed taxonomy" do
    expect(described_class.valid?("worker_infrastructure")).to be(true)
    expect(described_class.valid?("unknown_failure")).to be(false)
  end

  it "rejects an attempt with a classification outside the taxonomy" do
    attempt = build(:apple_verification_attempt, failure_classification: "unknown_failure")

    expect(attempt).not_to be_valid
    expect(attempt.errors[:failure_classification]).to be_present
  end
end
