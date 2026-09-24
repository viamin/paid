# frozen_string_literal: true

# Reconciles Apple verification attempts after restart and on a regular sweep.
# The recovery service expires overlong attempts before reconciling any VM
# ledger orphans, so terminal attempts enter the retained-and-locked-down path
# even when the guest or control plane stops reporting progress.
# @spec APPLE-ATTEMPT-004
# @spec APPLE-ATTEMPT-014
# @spec APPLE-TRANSFER-006
class AppleVerificationAttemptMaintenanceJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "apple_verification_attempt_maintenance"
  )

  def perform
    recovery_result = AppleVerificationAttempts::Recovery.call
    retention_result = AppleVerification::Bundles::RetentionSweep.call

    Rails.logger.info(
      message: "apple_verification_attempts.maintenance_complete",
      recovery: recovery_result.to_h,
      retention: retention_result.to_h
    )
  end
end
