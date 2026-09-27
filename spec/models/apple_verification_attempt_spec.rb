# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempt do
  # @spec APPLE-ATTEMPT-003
  describe "#queue_position" do
    it "returns the attempt's position in the fair queue" do
      attempt = create(:apple_verification_attempt)

      expect(attempt.queue_position).to eq(1)
    end
  end

  describe "failure_classification" do
    # @spec APPLE-ATTEMPT-009
    it "accepts a valid classification" do
      attempt = build(:apple_verification_attempt, failure_classification: "test_assertion")

      expect(attempt).to be_valid
    end

    it "rejects an invalid classification" do
      attempt = build(:apple_verification_attempt, failure_classification: "flaky")

      expect(attempt).not_to be_valid
      expect(attempt.errors[:failure_classification]).to be_present
    end

    it "allows nil for a terminal failed attempt" do
      attempt = build(:apple_verification_attempt, :failed, failure_classification: nil)

      expect(attempt).to be_valid
    end
  end
end
