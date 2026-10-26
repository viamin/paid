# frozen_string_literal: true

# Periodically recovers shadow-evaluation reviewer executions that stalled in
# a non-terminal queued/running state beyond the heartbeat staleness
# window (lost job, killed worker, hung provider past the perform timeout).
# Recovery is re-enqueue only: the executor's advisory lock leaves a live
# worker the sole lifecycle owner, pending cancellations are honored on
# resume, and executed cases are never re-spent.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
class ShadowEvaluationExecutionRecoveryJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "shadow_evaluation_execution_recovery"
  )

  def perform
    result = TenantContext.with_system_access do
      IntentConformance::ShadowEvaluation::RecoverStalledExecutions.call
    end

    return if result.requeued.zero? && result.scanned.zero?

    Rails.logger.info(
      message: "intent_conformance.shadow_evaluation_execution_recovery.completed",
      requeued: result.requeued,
      scanned: result.scanned
    )
  end
end
