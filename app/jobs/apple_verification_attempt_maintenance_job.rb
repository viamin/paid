# frozen_string_literal: true

# Reconciles Apple verification attempts after restart and on a regular sweep.
# The recovery service expires overlong attempts before reconciling any VM
# ledger orphans, so terminal attempts enter the retained-and-locked-down path
# even when the guest or control plane stops reporting progress.
# @spec APPLE-ATTEMPT-004
# @spec APPLE-ATTEMPT-001
# @spec APPLE-ATTEMPT-003
# @spec APPLE-ATTEMPT-005
# @spec APPLE-ATTEMPT-014
# @spec APPLE-TRANSFER-006
# @spec APPLE-ATTEMPT-015
class AppleVerificationAttemptMaintenanceJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "apple_verification_attempt_maintenance"
  )

  def perform
    record_worker_health
    admission_rechecks = recheck_active_attempt_admissions
    recovery_result = AppleVerificationAttempts::Recovery.call
    scheduling_result = AppleVerificationAttempts::Schedule.call
    retention_result = AppleVerification::Bundles::RetentionSweep.call

    Rails.logger.info(
      message: "apple_verification_attempts.maintenance_complete",
      recovery: recovery_result.to_h,
      scheduling: scheduling_result.to_h,
      retention: retention_result.to_h,
      admission_rechecks:
    )
  end

  private

  def record_worker_health
    lifecycle = AppleVerification::Lifecycle.from_environment
    return unless lifecycle

    AppleWorkerProfile.where(status: "active").find_each do |profile|
      AppleVerificationAttempts::WorkerHealth.call(profile:, lifecycle:)
    end
  end

  # @spec APPLE-ATTEMPT-002
  # Normal admission-threshold crossings are deliberately observational for
  # an already-active VM: Schedule will refuse subsequent admissions, while
  # the host lifecycle safety path remains the only authority that can stop a
  # running guest for an actual host-safety condition.
  def recheck_active_attempt_admissions
    rechecks = []
    AppleVerificationAttempt.active.includes(:project).find_each do |attempt|
      decision = AppleVerificationAttempts::Admission.recheck_admissions(project: attempt.project)
      log_admission_recheck(attempt, decision) unless decision.allowed?
      rechecks << { apple_verification_attempt_id: attempt.id, allowed: decision.allowed?, reason: decision.reason }
    end
    rechecks
  end

  def log_admission_recheck(attempt, decision)
    Rails.logger.warn(
      message: "apple_verification_attempts.admission_recheck_denied",
      apple_verification_attempt_id: attempt.id,
      account_id: attempt.account_id,
      project_id: attempt.project_id,
      reason: decision.reason
    )
  end
end
