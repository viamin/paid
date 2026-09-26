# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Validate do
  # @spec APPLE-ATTEMPT-005
  it "rejects an inactive worker profile before capacity is reserved" do
    attempt = create(:apple_verification_attempt)
    attempt.project.update!(apple_verification_mode: "on_demand")
    attempt.apple_worker_profile.update!(status: "deprecated")

    result = described_class.call(attempt:)

    expect(result).not_to be_valid
    expect(result.failure_classification).to eq("unsupported_capability")
  end
end
