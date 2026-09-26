# frozen_string_literal: true

# Reconciles in-flight Apple verification attempts whose verification VM is
# gone or orphaned after a control-plane/host restart or provisioning failure,
# converging each to `unavailable` so it is never left running indefinitely.
# Runs under system access because attempts span every account.
# @spec APPLE-ATTEMPT-014
class AppleVerificationRecoveryJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "apple_verification_recovery"
  )

  def perform
    result = TenantContext.with_system_access { AppleVerificationAttempts::Recovery.call }

    return if result.reconciled.zero? && result.scanned.zero?

    Rails.logger.info(
      message: "apple_verification_recovery.completed",
      reconciled: result.reconciled,
      scanned: result.scanned
    )
  end
end
