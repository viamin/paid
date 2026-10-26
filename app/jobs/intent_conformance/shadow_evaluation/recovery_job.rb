# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Requeues an interrupted worker after its heartbeat has expired. The
    # per-evaluation job key and advisory lock keep recovery from duplicating
    # provider work; ExecuteReviewer skips every persisted evaluated case.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class RecoveryJob < ApplicationJob
      include GoodJob::ActiveJobExtensions::Concurrency

      STALE_AFTER = 35.minutes

      queue_as :maintenance
      good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "shadow_evaluation_recovery")

      def perform
        IntentConformanceShadowEvaluation.where(status: "running")
          .where("execution_heartbeat_at < ?", STALE_AFTER.ago).find_each do |evaluation|
          recover(evaluation)
        end
      end

      private

      def recover(evaluation)
        evaluation.with_lock do
          return unless evaluation.running? && evaluation.execution_heartbeat_at < STALE_AFTER.ago

          evaluation.update!(status: "queued", last_failure_reason: "worker heartbeat expired; execution resumed")
          ExecuteJob.perform_later(evaluation.id)
        end
      end
    end
  end
end
