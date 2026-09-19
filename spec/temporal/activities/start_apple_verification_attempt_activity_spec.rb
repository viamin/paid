# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::StartAppleVerificationAttemptActivity do
  it "marks a queued attempt running" do # @spec APPLE-VERIFY-003
    attempt = create(:apple_verification_attempt)

    result = described_class.new.execute(attempt_id: attempt.id)

    expect(result).to eq(status: :running, attempt_id: attempt.id)
    expect(attempt.reload).to be_running
  end

  it "does not restart a cancelled attempt" do # @spec APPLE-VERIFY-003
    attempt = create(:apple_verification_attempt, state: "cancelled")

    result = described_class.new.execute(attempt_id: attempt.id)

    expect(result).to eq(status: :cancelled, attempt_id: attempt.id)
    expect(attempt.reload).to be_cancelled
  end
end
