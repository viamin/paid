# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # A lease makes an interrupted GoodJob perform recoverable: a later Resume
    # request can safely claim expired work, while per-case rows prevent spend
    # on already evaluated cases.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class ExecuteJob < ApplicationJob
      include GoodJob::ActiveJobExtensions::Concurrency

      queue_as :low_priority
      self.perform_timeout = 15.minutes
      good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1,
        key: -> { "shadow_evaluation_execution_#{arguments.first}" })
      discard_on ActiveRecord::RecordNotFound

      def perform(evaluation_id)
        evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
        return unless claim!(evaluation)

        result = ExecuteReviewer.call(evaluation:, cancelled: -> { evaluation.reload.cancel_requested? })
        mark_preflight_failure!(evaluation, result.error) unless result.success?
        CompileReport.call(evaluation:) if result.success? && evaluation.runs.exists?
      rescue StandardError => error
        fail_interrupted!(evaluation_id, error)
        raise
      ensure
        clear_lease!(evaluation_id)
      end

      private

      def tenant_account
        TenantContext.with_system_access do
          IntentConformanceShadowEvaluation.includes(project: :account).find_by(id: arguments.first)&.project&.account
        end
      end

      def claim!(evaluation)
        evaluation.with_lock do
          evaluation.reload
          return false if evaluation.cancelled? || evaluation.completed?
          return false unless evaluation.queued? || evaluation.running?
          return false if evaluation.running? && evaluation.execution_lease_expires_at&.future?

          evaluation.update!(status: "running", execute_started_at: Time.current,
            execution_lease_expires_at: 15.minutes.from_now)
          true
        end
      end

      def fail_interrupted!(evaluation_id, error)
        evaluation = IntentConformanceShadowEvaluation.find_by(id: evaluation_id)
        return unless evaluation

        evaluation.update!(status: evaluation.runs.exists? ? "partial" : "failed",
          last_failure_reason: "worker interrupted: #{error.class.name}")
        CompileReport.call(evaluation:) if evaluation.runs.exists?
      end

      def mark_preflight_failure!(evaluation, error)
        evaluation.update!(status: "failed", last_failure_reason: error)
      end

      def clear_lease!(evaluation_id)
        IntentConformanceShadowEvaluation.where(id: evaluation_id).update_all(execution_lease_expires_at: nil)
      end
    end
  end
end
