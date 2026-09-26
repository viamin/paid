# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationHostSafetyJob do
  # @spec APPLE-ATTEMPT-002

  it "invokes HostSafetyMonitor under system access" do
    in_system_access = false
    allow(TenantContext).to receive(:with_system_access) do |&block|
      in_system_access = true
      block.call
    end

    result = AppleVerificationAttempts::HostSafetyMonitor::Result.new(terminated: 1, scanned: 2)
    allow(AppleVerificationAttempts::HostSafetyMonitor).to receive(:call).and_return(result)

    described_class.new.perform

    expect(in_system_access).to be(true)
    expect(AppleVerificationAttempts::HostSafetyMonitor).to have_received(:call)
  end

  it "logs the terminated and scanned counts when non-zero" do
    allow(TenantContext).to receive(:with_system_access).and_yield

    result = AppleVerificationAttempts::HostSafetyMonitor::Result.new(terminated: 1, scanned: 2)
    allow(AppleVerificationAttempts::HostSafetyMonitor).to receive(:call).and_return(result)

    logger = instance_double(ActiveSupport::Logger)
    allow(Rails).to receive(:logger).and_return(logger)
    expect(logger).to receive(:info).with(
      message: "apple_verification_host_safety.completed",
      terminated: 1,
      scanned: 2
    )

    described_class.new.perform
  end

  it "does not log when nothing was scanned" do
    allow(TenantContext).to receive(:with_system_access).and_yield

    result = AppleVerificationAttempts::HostSafetyMonitor::Result.new(terminated: 0, scanned: 0)
    allow(AppleVerificationAttempts::HostSafetyMonitor).to receive(:call).and_return(result)

    logger = instance_double(ActiveSupport::Logger)
    allow(Rails).to receive(:logger).and_return(logger)
    expect(logger).not_to receive(:info)

    described_class.new.perform
  end
end
