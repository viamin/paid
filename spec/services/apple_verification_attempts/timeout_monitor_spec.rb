# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::TimeoutMonitor do
  # @spec APPLE-ATTEMPT-004
  it "times out overdue attempts as an infrastructure result" do
    attempt = create(:apple_verification_attempt, status: "running", started_at: 46.minutes.ago)

    described_class.call

    expect(attempt.reload).to have_attributes(status: "timed_out", failure_classification: "cancellation_or_timeout")
  end

  it "applies its configured failed-VM retention duration" do
    attempt = create(:apple_verification_attempt, status: "running", started_at: 2.minutes.ago)
    configuration = AppleVerificationAttempts::Configuration.new(attempt_timeout: 1.minute, failed_vm_retention: 5.minutes)

    described_class.call(configuration:)

    expect(attempt.reload.container_retained_until).to be_within(2.seconds).of(5.minutes.from_now)
  end

  it "stops the VM before recording the timeout" do
    attempt = create(:apple_verification_attempt, status: "running", started_at: 46.minutes.ago)
    lifecycle = instance_double(AppleVerification::Lifecycle)
    allow(lifecycle).to receive(:stop).and_return(:stopped)

    described_class.call(lifecycle:)

    expect(lifecycle).to have_received(:stop).with(attempt:, request_id: "attempt:stop:#{attempt.id}")
  end

  it "still ends the attempt when stopping the VM is refused because workers are disabled" do
    attempt = create(:apple_verification_attempt, status: "running", started_at: 46.minutes.ago)
    lifecycle = instance_double(AppleVerification::Lifecycle)
    allow(lifecycle).to receive(:stop)
      .and_raise(AppleVerification::HostService::UnsupportedRequestError, "Apple verification workers are disabled")

    expect { described_class.call(lifecycle:) }.to change { attempt.reload.status }.from("running").to("timed_out")
    expect(attempt.reload).to have_attributes(failure_classification: "cancellation_or_timeout")
  end

  it "still ends the attempt when the host service is unreachable" do
    attempt = create(:apple_verification_attempt, status: "running", started_at: 46.minutes.ago)
    lifecycle = instance_double(AppleVerification::Lifecycle)
    allow(lifecycle).to receive(:stop).and_raise(Faraday::ConnectionFailed.new("host down"))

    expect { described_class.call(lifecycle:) }.to change { attempt.reload.status }.from("running").to("timed_out")
  end

  it "revokes credentials even when stopping the VM fails" do
    attempt = create(:apple_verification_attempt, status: "running", started_at: 46.minutes.ago)
    lifecycle = instance_double(AppleVerification::Lifecycle)
    allow(lifecycle).to receive(:stop).and_raise(Faraday::ConnectionFailed.new("host down"))
    revocation = instance_double(AppleVerification::Revocation::Enforce)
    allow(revocation).to receive(:call)

    AppleVerificationAttempts::Cancel.call(attempt:, lifecycle:, revocation:, outcome: "timed_out")

    expect(revocation).to have_received(:call)
  end
end
