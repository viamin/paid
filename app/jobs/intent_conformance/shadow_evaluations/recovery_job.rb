# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluations
    # Bounded recovery for the async shadow-evaluation execution (#4642):
    # a killed worker, expired request, or lost advisory lock must never
    # strand an evaluation indefinitely as queued/running. The executor
    # heartbeats after every corpus case, so a stale heartbeat means no live
    # worker is making progress: the sweep returns such records to a
    # retryable state with the collected evidence preserved (and the report
    # recompiled from it), and re-enqueues stale queued claims whose job row
    # vanished. Nothing here fabricates evaluated verdicts — remaining cases
    # simply keep no run row until an operator retries.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class RecoveryJob < ApplicationJob
      include GoodJob::ActiveJobExtensions::Concurrency

      STALE_AFTER = IntentConformance::ShadowEvaluation::RecoverStaleExecution::STALE_AFTER

      queue_as :maintenance

      good_job_control_concurrency_with(
        total_limit: 1,
        enqueue_limit: 1,
        key: "intent_conformance_shadow_evaluation_recovery"
      )

      def perform
        result = TenantContext.with_system_access { IntentConformance::ShadowEvaluation::RecoverStaleExecution.call }

        return if result.recovered.zero? && result.requeued.zero?

        Rails.logger.info(
          message: "intent_conformance.shadow_execution_recovery.completed",
          recovered_count: result.recovered,
          requeued_count: result.requeued,
          stale_after_seconds: STALE_AFTER.to_i
        )
      end
    end
  end
end
