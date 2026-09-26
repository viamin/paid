# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationRetryJob do
  # @spec APPLE-ATTEMPT-010

  it "invokes RetryMonitor under system access" do
    in_system_access = false
    allow(TenantContext).to receive(:with_system_access) do |&block|
      in_system_access = true
      block.call
    end

    result = AppleVerificationAttempts::RetryMonitor::Result.new(retried: 1, scanned: 2)
    allow(AppleVerificationAttempts::RetryMonitor).to receive(:call).and_return(result)

    described_class.new.perform

    expect(in_system_access).to be(true)
    expect(AppleVerificationAttempts::RetryMonitor).to have_received(:call)
  end

  it "logs the retried and scanned counts when non-zero" do
    allow(TenantContext).to receive(:with_system_access).and_yield

    result = AppleVerificationAttempts::RetryMonitor::Result.new(retried: 1, scanned: 2)
    allow(AppleVerificationAttempts::RetryMonitor).to receive(:call).and_return(result)

    logger = instance_double(ActiveSupport::Logger)
    allow(Rails).to receive(:logger).and_return(logger)
    expect(logger).to receive(:info).with(
      message: "apple_verification_retry.completed",
      retried: 1,
      scanned: 2
    )

    described_class.new.perform
  end

  it "does not log when nothing was scanned" do
    allow(TenantContext).to receive(:with_system_access).and_yield

    result = AppleVerificationAttempts::RetryMonitor::Result.new(retried: 0, scanned: 0)
    allow(AppleVerificationAttempts::RetryMonitor).to receive(:call).and_return(result)

    logger = instance_double(ActiveSupport::Logger)
    allow(Rails).to receive(:logger).and_return(logger)
    expect(logger).not_to receive(:info)

    described_class.new.perform
  end
end
