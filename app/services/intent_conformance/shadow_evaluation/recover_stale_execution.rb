# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Returns stranded executions to a retryable state (#4642). Two bounded
    # cases, both driven by persisted timestamps so recovery needs no
    # process-local state:
    #
    # - `running` (or legacy `executing`) whose heartbeat/start stamp is
    #   older than STALE_AFTER: no live worker is progressing. The record
    #   becomes partial when any evaluated verdict was collected (failed
    #   otherwise), the reason names the interruption, and the available
    #   report is recompiled. The advisory lock dies with the worker's
    #   database session, so a retry can proceed immediately.
    # - `queued` past the same bound whose job row was lost: re-enqueue the
    #   idempotent ExecuteJob (the evaluated-verdict skip keeps it free of
    #   repeated spend) and restamp the queue time so recovery retries at a
    #   bounded cadence rather than every sweep.
    #
    # Never fabricates evidence: untouched cases keep no run row.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class RecoverStaleExecution
      Result = Data.define(:recovered, :requeued) do
        def success? = true
      end

      # Generous ceiling over a single slow-provider reviewer invocation:
      # the executor heartbeats between cases, so only a genuinely dead
      # worker (or one blocked far past a case) trips this.
      STALE_AFTER = 30.minutes

      def self.call(...) = new(...).call

      def initialize(now: Time.current)
        @now = now
      end

      def call
        Result.new(recovered: recover_interrupted, requeued: requeue_lost)
      end

      private

      def recover_interrupted
        stale = IntentConformanceShadowEvaluation.running
          .where(id: IntentConformanceShadowEvaluation.where(
            "COALESCE(execute_heartbeat_at, execute_started_at) < ?", @now - STALE_AFTER
          ).select(:id))
        stale.count.tap do
          stale.find_each { |evaluation| recover(evaluation) }
        end
      end

      def recover(evaluation)
        evaluated = evaluation.runs.where.not(verdict: "not_evaluated").count
        status = evaluated.positive? ? "partial" : "failed"
        evaluation.update!(status: status, last_failure_reason: interruption_reason)
        CancelExecution.compile_available_report(evaluation)
        Rails.logger.warn(
          message: "intent_conformance.shadow_execution_recovered",
          project_id: evaluation.project_id,
          shadow_evaluation_id: evaluation.id,
          recovered_status: status,
          evaluated_count: evaluated
        )
      end

      def interruption_reason
        "execution interrupted — worker died or lost the execution lock; collected evidence preserved; retry to evaluate the remaining cases"
      end

      def requeue_lost
        stale_queued = IntentConformanceShadowEvaluation.queued.where(execute_queued_at: ...@now - STALE_AFTER)
        stale_queued.count.tap do
          stale_queued.find_each do |evaluation|
            evaluation.update_column(:execute_queued_at, @now)
            IntentConformance::ShadowEvaluations::ExecuteJob.perform_later(evaluation.id)
          end
        end
      end
    end
  end
end
