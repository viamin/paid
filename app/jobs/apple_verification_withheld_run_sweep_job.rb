# frozen_string_literal: true

# Resolves runs whose completion was withheld at the completion-verification gate
# (`AppleVerificationAttempts::GateEnforcement`, APPLE-ATTEMPT-013) by invoking
# `AppleVerificationAttempts::CompleteWithheldRun` for each one. The original
# workflow already returned success to Temporal. The attempt-success and waiver
# paths re-invoke completion synchronously, while this periodic reminder covers
# runs whose gate later relaxes via:
#
#   * operator disabling the `apple_verification_workers` rollout flag
#   * operator switching the project mode to `off`
#   * the approved revision being superseded or disabled (so `binding_revision`
#     later returns nil and the gate moves to `not_required`)
#
# This fallback ensures those configuration changes do not leave a withheld run
# `running` indefinitely when neither synchronous path fires.
# @spec APPLE-ATTEMPT-013
class AppleVerificationWithheldRunSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "apple_verification_withheld_run_sweep"
  )

  def perform
    completed = 0
    skipped = 0

    TenantContext.with_system_access do
      AgentRun.awaiting_completion_verification.find_each do |agent_run|
        AppleVerificationAttempts::CompleteWithheldRun.call(agent_run: agent_run)
        completed += 1
      rescue => e
        skipped += 1
        Rails.logger.error(
          message: "apple_verification_withheld_run_sweep.run_failed",
          agent_run_id: agent_run.id,
          project_id: agent_run.project_id,
          error_class: e.class.name,
          error: e.message
        )
      end
    end

    return if completed.zero? && skipped.zero?

    Rails.logger.info(
      message: "apple_verification_withheld_run_sweep.completed",
      completed: completed,
      skipped: skipped
    )
  end
end
