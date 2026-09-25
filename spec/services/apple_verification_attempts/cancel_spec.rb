# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-006
# @spec APPLE-VERIFY-006
RSpec.describe AppleVerificationAttempts::Cancel do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  it "classifies and finalizes a cancelled running attempt immediately" do
    attempt = create(:apple_verification_attempt, project:, account:, status: "running", started_at: Time.current)

    described_class.call(attempt:)

    expect(attempt.reload).to have_attributes(
      status: "cancelled",
      failure_classification: "cancellation_or_timeout"
    )
    expect(attempt.finished_at).to be_present
    expect(attempt.finalized_at).to be_present
    expect(attempt.container_retained_until).to be_present
  end
end
