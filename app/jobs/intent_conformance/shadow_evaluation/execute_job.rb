# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Durable worker entrypoint for a queued shadow-review evaluation.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class ExecuteJob < ApplicationJob
      include GoodJob::ActiveJobExtensions::Concurrency

      queue_as :low_priority
      self.perform_timeout = 30.minutes
      good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1,
        key: -> { "shadow_evaluation_#{arguments.first}" })
      discard_on ActiveRecord::RecordNotFound

      def perform(evaluation_id)
        evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
        return if evaluation.cancelled?

        result = ExecuteReviewer.call(evaluation:)
        CompileReport.call(evaluation:) if result.success? && evaluation.runs.exists?
      rescue StandardError => error
        evaluation&.update!(status: "partial", last_failure_reason: error.message) unless evaluation&.cancelled?
        raise
      end

      private

      def tenant_account
        TenantContext.with_system_access do
          IntentConformanceShadowEvaluation.find_by(id: arguments.first)&.project&.account
        end
      end
    end
  end
end
