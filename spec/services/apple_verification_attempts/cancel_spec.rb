# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Cancel do
  # @spec APPLE-ATTEMPT-006
  it "applies the configured failed-VM retention duration when cancelling a running attempt" do
    attempt = create(:apple_verification_attempt, status: "running")
    configuration = AppleVerificationAttempts::Configuration.new(failed_vm_retention: 5.minutes)

    described_class.call(attempt:, configuration:)

    expect(attempt.reload.container_retained_until).to be_within(2.seconds).of(5.minutes.from_now)
  end
end
