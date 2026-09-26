# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttemptSchedulerJob do
  # @spec APPLE-ATTEMPT-003
  it "invokes the fair scheduler when the trusted host is configured" do
    host_capacity = instance_double(AppleVerificationAttempts::HostCapacity)
    lifecycle = instance_double(AppleVerification::Lifecycle)
    allow(AppleVerificationAttempts::HostCapacity).to receive(:from_environment).and_return(host_capacity)
    allow(AppleVerification::Lifecycle).to receive(:from_environment).and_return(lifecycle)

    expect(AppleVerificationAttempts::Scheduler).to receive(:call) do |capacity:, dispatcher:|
      expect(capacity).to eq(host_capacity)
      expect(dispatcher).to be_a(AppleVerificationAttempts::Provision)
    end

    described_class.perform_now
  end

  it "does not schedule when the trusted host is not configured" do
    allow(AppleVerificationAttempts::HostCapacity).to receive(:from_environment).and_return(nil)

    expect(AppleVerificationAttempts::Scheduler).not_to receive(:call)

    described_class.perform_now
  end
end
