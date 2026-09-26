# frozen_string_literal: true

# Periodically times out Apple verification attempts stuck in a non-terminal
# `provisioning`/`running` state beyond the configured attempt timeout, driving
# VM revocation and retention through `AppleVerificationAttempts::Complete`.
# @spec APPLE-ATTEMPT-004
class AppleVerificationTimeoutJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "apple_verification_timeout"
  )

  def perform
    result = TenantContext.with_system_access do
      AppleVerificationAttempts::TimeoutMonitor.call
    end

    return if result.timed_out.zero? && result.scanned.zero?

    Rails.logger.info(
      message: "apple_verification_timeout.completed",
      timed_out: result.timed_out,
      scanned: result.scanned
    )
  end
end
