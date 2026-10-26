# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Durable worker boundary for potentially slow reviewer calls. A retry that
    # finds `running` recovers the old worker's state and resumes from the
    # persisted per-case evidence without repeating evaluated cases.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class ExecuteJob < ApplicationJob
      queue_as :low_priority
      self.perform_timeout = 30.minutes

      include GoodJob::ActiveJobExtensions::Concurrency
      good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1,
        key: -> { "intent_conformance_shadow_evaluation_#{arguments.first}" })

      discard_on ActiveRecord::RecordNotFound

      def perform(evaluation_id)
        evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
        return unless start!(evaluation)

        result = ExecuteReviewer.call(evaluation:)
        if result.success?
          CompileReport.call(evaluation:)
        else
          settle_reviewer_failure!(evaluation, result.error)
        end
      rescue StandardError => error
        fail!(evaluation, error)
        CompileReport.call(evaluation:) if evaluation&.runs&.exists?
        raise
      end

      private

      def start!(evaluation)
        evaluation.with_lock do
          return false if evaluation.cancel_requested? || evaluation.cancelled? || evaluation.completed?

          recovered = evaluation.running?
          evaluation.update!(status: "running", execute_started_at: Time.current,
            last_failure_reason: ("previous worker interrupted; resuming remaining cases" if recovered))
        end
        true
      end

      def fail!(evaluation, error)
        return unless evaluation

        evaluation.with_lock do
          next if evaluation.cancelled?

          evaluation.update!(status: "failed", last_failure_reason: error.message)
        end
      end

      def settle_reviewer_failure!(evaluation, reason)
        evaluation.with_lock do
          next if evaluation.cancelled?

          evaluation.update!(status: "failed", last_failure_reason: reason)
        end
      end

      def tenant_account
        IntentConformanceShadowEvaluation.find_by(id: arguments.first)&.project&.account
      end
    end
  end
end
