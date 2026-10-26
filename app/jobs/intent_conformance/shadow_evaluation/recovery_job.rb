# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Re-enqueues abandoned work after process loss or an expired job timeout.
    # Completed case rows are never submitted to the provider again.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class RecoveryJob < ApplicationJob
      include GoodJob::ActiveJobExtensions::Concurrency

      STALE_AFTER = 35.minutes

      queue_as :maintenance
      good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "intent_conformance_shadow_evaluation_recovery")

      def perform
        TenantContext.with_system_access do
          IntentConformanceShadowEvaluation.where(status: %w[queued running])
            .where("COALESCE(execution_heartbeat_at, execution_enqueued_at) < ? OR (execution_heartbeat_at IS NULL AND execution_enqueued_at IS NULL)", STALE_AFTER.ago)
            .find_each { |evaluation| recover(evaluation) }
        end
      end

      private

      def recover(evaluation)
        evaluation.with_lock do
          if evaluation.execution_cancel_requested?
            evaluation.update!(status: "cancelled", last_failure_reason: "execution cancelled; collected reviewer evidence was preserved")
            return
          end

          evaluation.update!(status: "queued", execution_enqueued_at: Time.current, execution_heartbeat_at: nil,
            last_failure_reason: "execution worker interrupted; resuming incomplete cases")
        end
        ExecuteJob.perform_later(evaluation.project_id, evaluation.id)
      end
    end
  end
end
