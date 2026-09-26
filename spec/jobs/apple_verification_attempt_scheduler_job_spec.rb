# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttemptSchedulerJob do
  # @spec APPLE-ATTEMPT-003
  it "invokes the fair scheduler when the trusted host is configured" do
    lifecycle = instance_double(AppleVerification::Lifecycle)
    allow(AppleVerificationAttempts::HostCapacity).to receive(:configured?).and_return(true)
    allow(AppleVerification::Lifecycle).to receive(:from_environment).and_return(lifecycle)

    expect(AppleVerificationAttempts::Scheduler).to receive(:call) do |capacity:, dispatcher:|
      expect(capacity).to be_a(AppleVerificationAttempts::HostCapacity)
      expect(dispatcher).to be_a(AppleVerificationAttempts::Provision)
    end

    described_class.perform_now
  end
end
