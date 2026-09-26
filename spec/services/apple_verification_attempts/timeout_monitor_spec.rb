# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::TimeoutMonitor do
  # @spec APPLE-ATTEMPT-004
  it "times out overdue attempts as an infrastructure result" do
    attempt = create(:apple_verification_attempt, status: "running", started_at: 46.minutes.ago)

    described_class.call

    expect(attempt.reload).to have_attributes(status: "timed_out", failure_classification: "cancellation_or_timeout")
  end
end
