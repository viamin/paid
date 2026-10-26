# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Durable worker boundary for a corpus run. Retryable worker failures are
    # retried by Active Job; terminal failures remain visible on the evaluation.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class ExecuteJob < ApplicationJob
      queue_as :default
      self.notification_subsystem = "intent_conformance"
      self.max_attempts = 3

      retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
        job.mark_failed(error)
        raise error
      end

      def notification_project_id
        TenantContext.with_system_access { IntentConformanceShadowEvaluation.find_by(id: arguments.first)&.project_id }
      end

      def perform(evaluation_id)
        evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
        return if evaluation.cancelled? || evaluation.completed?

        evaluation.with_lock do
          return if evaluation.cancelled? || evaluation.completed?

          evaluation.update!(status: "running", execution_heartbeat_at: Time.current)
        end
        result = ExecuteReviewer.call(evaluation:)
        CompileReport.call(evaluation:) if result.success? && evaluation.runs.exists?
      end

      def mark_failed(error)
        TenantContext.with_system_access do
          evaluation = IntentConformanceShadowEvaluation.find_by(id: arguments.first)
          evaluation&.update!(status: evaluation.runs.exists? ? "partial" : "failed",
            last_failure_reason: error.message, execution_heartbeat_at: Time.current) unless evaluation&.cancelled?
        end
      end
    end
  end
end
