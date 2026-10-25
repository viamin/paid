# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Bounded asynchronous recovery for shadow-evaluation executions
    # (#4642): a killed worker, expired request, or lost execution lock must
    # not strand an evaluation indefinitely as executing or queued. The
    # sweep probes each execution's per-case heartbeat and its advisory
    # execution lock — a live worker holding the lock is never interrupted —
    # then resumes stranded executions within a bounded number of automatic
    # attempts and fails the ones that keep getting interrupted (a manual
    # retry from the evaluation screen always remains available).
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class RecoveryJob < ApplicationJob
      include GoodJob::ActiveJobExtensions::Concurrency

      MAX_RECOVERY_RESUMES = 3
      STALE_EXECUTION_AFTER = EnqueueExecution::STALE_EXECUTION_AFTER

      queue_as :maintenance
      good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1,
        key: "intent_conformance_shadow_evaluation_recovery")

      def perform
        result = TenantContext.with_system_access { sweep }

        return if result[:resumed].zero? && result[:failed].zero? && result[:cancelled].zero?

        Rails.logger.info(
          message: "intent_conformance.shadow_execution_recovery_completed",
          resumed_count: result[:resumed],
          failed_count: result[:failed],
          cancelled_count: result[:cancelled],
          scanned_count: result[:scanned]
        )
      end

      private

      def sweep
        resumed = 0
        failed = 0
        cancelled = 0
        scanned = 0
        IntentConformanceShadowEvaluation.where(status: %w[queued executing]).find_each do |evaluation|
          scanned += 1
          next if heartbeat_fresh?(evaluation)
          next if ExecutionLock.held_by_other_session?(evaluation.id)

          if evaluation.cancel_requested_at.present?
            # Never resurrect spend an operator asked to stop: the worker
            # died before honoring the flag, so finish the cancellation here.
            cancel_stranded(evaluation)
            cancelled += 1
          elsif resume_budget_exhausted?(evaluation)
            fail_stranded(evaluation)
            failed += 1
          else
            resume(evaluation)
            resumed += 1
          end
        end
        { resumed: resumed, failed: failed, cancelled: cancelled, scanned: scanned }
      end

      def heartbeat_fresh?(evaluation)
        heartbeat = evaluation.execute_heartbeat_at
        heartbeat.present? && heartbeat > STALE_EXECUTION_AFTER.ago
      end

      def resume_budget_exhausted?(evaluation)
        evaluation.execution_attempts >= MAX_RECOVERY_RESUMES
      end

      def resume(evaluation)
        evaluation.update!(
          status: "queued",
          cancel_requested_at: nil,
          last_failure_reason: nil,
          execute_heartbeat_at: Time.current,
          execution_attempts: evaluation.execution_attempts + 1
        )
        ExecuteJob.perform_later(evaluation.id)
      end

      def cancel_stranded(evaluation)
        evaluation.update!(
          status: "cancelled",
          last_failure_reason: "execution cancelled by operator; collected reviewer evidence is preserved"
        )
      end

      def fail_stranded(evaluation)
        evaluation.update!(
          status: "failed",
          last_failure_reason: "execution was interrupted repeatedly (worker died or lost the execution lock); retry manually from the evaluation screen"
        )
      end
    end
  end
end
