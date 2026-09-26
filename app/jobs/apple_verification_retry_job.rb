# frozen_string_literal: true

# Re-enqueues Apple verification attempts that failed for infrastructure
# reasons, bounded by the retry limit and queue depth. Runs under system access
# because attempts span every account.
# @spec APPLE-ATTEMPT-010
class AppleVerificationRetryJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "apple_verification_retry"
  )

  def perform
    result = TenantContext.with_system_access { AppleVerificationAttempts::RetryMonitor.call }

    return if result.retried.zero? && result.scanned.zero?

    Rails.logger.info(
      message: "apple_verification_retry.completed",
      retried: result.retried,
      scanned: result.scanned
    )
  end
end
