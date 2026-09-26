# frozen_string_literal: true

# Periodically advances the fair Apple verification queue through capacity
# admission and VM lifecycle provisioning. It runs under system access because
# a single Apple worker serves attempts from every account.
# @spec APPLE-ATTEMPT-003
class AppleVerificationDispatchJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "apple_verification_dispatch"
  )

  def perform
    result = TenantContext.with_system_access { AppleVerificationAttempts::Dispatcher.call }

    return if result.started.zero? && result.rejected.zero?

    Rails.logger.info(
      message: "apple_verification_dispatch.completed",
      started: result.started,
      rejected: result.rejected
    )
  end
end
