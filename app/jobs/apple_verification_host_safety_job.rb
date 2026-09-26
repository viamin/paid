# frozen_string_literal: true

# Stops active Apple verification attempts when the host is no longer safe to
# run them (sustained critical memory pressure or exhausted host disk),
# converging each to `unavailable` so it is never left running on an unsafe
# host. Runs under system access because attempts span every account.
# @spec APPLE-ATTEMPT-002
class AppleVerificationHostSafetyJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "apple_verification_host_safety"
  )

  def perform
    result = TenantContext.with_system_access { AppleVerificationAttempts::HostSafetyMonitor.call }

    return if result.terminated.zero? && result.scanned.zero?

    Rails.logger.info(
      message: "apple_verification_host_safety.completed",
      terminated: result.terminated,
      scanned: result.scanned
    )
  end
end
