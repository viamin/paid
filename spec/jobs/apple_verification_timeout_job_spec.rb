# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationTimeoutJob do
  # @spec APPLE-ATTEMPT-004

  it "invokes TimeoutMonitor under system access" do
    in_system_access = false
    allow(TenantContext).to receive(:with_system_access) do |&block|
      in_system_access = true
      block.call
    end

    result = AppleVerificationAttempts::TimeoutMonitor::Result.new(timed_out: 2, scanned: 5)
    allow(AppleVerificationAttempts::TimeoutMonitor).to receive(:call).and_return(result)

    described_class.new.perform

    expect(in_system_access).to be(true)
    expect(AppleVerificationAttempts::TimeoutMonitor).to have_received(:call)
  end

  it "logs the timed_out and scanned counts when non-zero" do
    allow(TenantContext).to receive(:with_system_access).and_yield

    result = AppleVerificationAttempts::TimeoutMonitor::Result.new(timed_out: 2, scanned: 5)
    allow(AppleVerificationAttempts::TimeoutMonitor).to receive(:call).and_return(result)

    logger = instance_double(ActiveSupport::Logger)
    allow(Rails).to receive(:logger).and_return(logger)
    expect(logger).to receive(:info).with(
      message: "apple_verification_timeout.completed",
      timed_out: 2,
      scanned: 5
    )

    described_class.new.perform
  end

  it "does not log when nothing was scanned" do
    allow(TenantContext).to receive(:with_system_access).and_yield

    result = AppleVerificationAttempts::TimeoutMonitor::Result.new(timed_out: 0, scanned: 0)
    allow(AppleVerificationAttempts::TimeoutMonitor).to receive(:call).and_return(result)

    logger = instance_double(ActiveSupport::Logger)
    allow(Rails).to receive(:logger).and_return(logger)
    expect(logger).not_to receive(:info)

    described_class.new.perform
  end
end
