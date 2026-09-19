# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempt do
  it "requires a reason for a one-attempt waiver" do # @spec APPLE-VERIFY-003
    attempt = build(:apple_verification_attempt, state: "waived")

    expect(attempt).to be_invalid
    expect(attempt.errors[:waiver_reason]).to be_present
  end

  it "keeps infrastructure and project failures distinct" do # @spec APPLE-VERIFY-003
    expect(build(:apple_verification_attempt, failure_class: "infrastructure")).to be_valid
    expect(build(:apple_verification_attempt, failure_class: "compile")).to be_valid
  end
end
