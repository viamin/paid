# frozen_string_literal: true

# Admits one fair queue head and starts its trusted Apple VM lifecycle.
# @spec APPLE-ATTEMPT-003
class AppleVerificationAttemptSchedulerJob < ApplicationJob
  queue_as :default

  def perform
    capacity = AppleVerificationAttempts::HostCapacity.from_environment
    return unless capacity

    lifecycle = AppleVerification::Lifecycle.from_environment
    AppleVerificationAttempts::Scheduler.call(
      capacity:,
      dispatcher: AppleVerificationAttempts::Provision.new(lifecycle:)
    )
  end
end
