# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Background execution of a frozen shadow evaluation (#4642): runs the
    # real intent-conformance reviewer for every corpus case without an
    # evaluated verdict through the existing ExecuteReviewer service (same
    # freeze/identity/blinding/dedup semantics), then compiles the available
    # report through CompileReport. The job is idempotent — only the queued
    # state starts execution, so a cancelled evaluation, a superseded
    # duplicate, or a recovered re-enqueue never double-spends. A killed
    # worker is bounded by the recovery sweep plus the evaluation heartbeat.
    # @spec INTENT-CONFORMANCE-ROLLOUT-007
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class ExecuteJob < ApplicationJob
      include GoodJob::ActiveJobExtensions::Concurrency

      # Raised when a synchronous invocation (console/console-like tool)
      # still holds the advisory execution lock; retried rather than failed
      # so the queued lifecycle converges once the holder finishes.
      class ExecutionLockHeld < StandardError; end

      queue_as :low_priority
      # A 30-case corpus multiplies single-review latency; the ceiling only
      # backstops a hung provider call — each case persists its own run, so
      # an aborted perform resumes without repeated completed-case spend.
      self.perform_timeout = 2.hours
      good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 4,
        key: -> { "intent_conformance_shadow_evaluation_execute_#{arguments.first}" })
      retry_on ExecutionLockHeld, wait: :polynomially_longer, attempts: 5
      discard_on ActiveRecord::RecordNotFound

      def perform(evaluation_id)
        evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
        return unless evaluation.queued?

        result = ExecuteReviewer.call(evaluation: evaluation)
        raise ExecutionLockHeld, result.error if lock_contention?(result)

        finalize(evaluation, result)
      end

      private

      def lock_contention?(result)
        !result.success? && result.error.to_s.include?("already in progress")
      end

      def finalize(evaluation, result)
        if result.success?
          # Available evidence compiles through the existing report service —
          # including a cancelled run: its unvisited cases surface as not
          # evaluated, never as agreement.
          IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation.reload) if evaluation.runs.exists?
          log_finished(evaluation, result)
        else
          # Validation failed at perform time (state changed between enqueue
          # and perform, e.g. the manifest moved): persist the reason instead
          # of stranding the evaluation as queued.
          evaluation.update!(status: "failed", last_failure_reason: result.error)
          log_finished(evaluation, result)
        end
      end

      def log_finished(evaluation, result)
        Rails.logger.info(
          message: "intent_conformance.shadow_evaluation_execute_job_finished",
          project_id: evaluation.project_id,
          shadow_evaluation_id: evaluation.id,
          status: evaluation.reload.status,
          executed_count: result.executed,
          failed_count: result.failed,
          cancelled: result.cancelled? || false
        )
      end

      # The first argument is the evaluation id, not a project id — resolve
      # the tenant through the evaluation's project so the reviewer's GitHub
      # client and any Current.account readers stay tenant-correct on the
      # worker thread.
      def tenant_account
        IntentConformanceShadowEvaluation.find_by(id: arguments.first)&.project&.account
      end

      def notification_project_id
        IntentConformanceShadowEvaluation.find_by(id: arguments.first)&.project_id
      end
    end
  end
end
