# frozen_string_literal: true

# Admits one fair queue head and starts its trusted Apple VM lifecycle.
# @spec APPLE-ATTEMPT-003
class AppleVerificationAttemptSchedulerJob < ApplicationJob
  queue_as :default

  def perform
    return unless AppleVerificationAttempts::HostCapacity.configured?

    lifecycle = AppleVerification::Lifecycle.from_environment
    AppleVerificationAttempts::Scheduler.call(
      capacity: AppleVerificationAttempts::HostCapacity.new,
      dispatcher: AppleVerificationAttempts::Provision.new(lifecycle:)
    )
  end
end
