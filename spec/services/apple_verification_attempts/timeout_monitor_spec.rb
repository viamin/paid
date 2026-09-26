# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::TimeoutMonitor do
  # @spec APPLE-ATTEMPT-004
  it "times out overdue attempts as an infrastructure result" do
    attempt = create(:apple_verification_attempt, status: "running", started_at: 46.minutes.ago)

    described_class.call

    expect(attempt.reload).to have_attributes(status: "timed_out", failure_classification: "cancellation_or_timeout")
  end

  it "stops the VM before recording the timeout" do
    attempt = create(:apple_verification_attempt, status: "running", started_at: 46.minutes.ago)
    lifecycle = instance_double(AppleVerification::Lifecycle)
    allow(lifecycle).to receive(:stop).and_return(:stopped)

    described_class.call(lifecycle:)

    expect(lifecycle).to have_received(:stop).with(attempt:, request_id: "attempt:stop:#{attempt.id}")
  end
end
