# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Bounded asynchronous recovery (#4642): a queued evaluation whose job
    # was lost and a running evaluation whose worker heartbeat went stale
    # (killed worker — its advisory lock dies with its database session) are
    # recovered by re-enqueueing the execution job. Re-enqueueing is always
    # safe: the advisory lock leaves a live worker the sole lifecycle owner,
    # a requested cancellation is honored on resume, and executed cases are
    # never re-spent. No evaluation can therefore strand indefinitely as
    # queued/executing.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class RecoverStalledExecutions
      Result = Data.define(:requeued, :scanned)

      STALE_AFTER = 30.minutes

      def self.call(now: Time.current)
        new(now: now).call
      end

      def initialize(now:)
        @now = now
      end

      def call
        requeued = 0
        scanned = 0
        cutoff = @now - STALE_AFTER

        IntentConformanceShadowEvaluation.where(status: %w[queued running executing]).find_each do |evaluation|
          scanned += 1
          next unless stalled?(evaluation, cutoff)

          requeued += 1 if requeue(evaluation)
        end

        Result.new(requeued: requeued, scanned: scanned)
      end

      private

      def stalled?(evaluation, cutoff)
        stamp = case evaluation.status
        when "queued" then evaluation.execution_queued_at
        else evaluation.execution_heartbeat_at || evaluation.execute_started_at || evaluation.updated_at
        end
        return false if stamp.blank?

        stamp <= cutoff
      end

      def requeue(evaluation)
        ShadowEvaluationExecuteJob.perform_later(evaluation.id)
        Rails.logger.warn(
          message: "intent_conformance.shadow_evaluation_execution_requeued",
          shadow_evaluation_id: evaluation.id,
          project_id: evaluation.project_id,
          status: evaluation.status,
          cancel_requested: evaluation.cancel_requested_at.present?
        )
        true
      end
    end
  end
end
