# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    class ExecuteJob < ApplicationJob # @spec INTENT-CONFORMANCE-ROLLOUT-011
      include GoodJob::ActiveJobExtensions::Concurrency

      queue_as :low_priority
      self.perform_timeout = 30.minutes
      good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1,
        key: -> { "intent_conformance_shadow_evaluation_#{arguments.second}" })
      discard_on ActiveRecord::RecordNotFound

      def perform(project_id, evaluation_id)
        evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
        return unless evaluation.project_id == project_id
        return if evaluation.cancelled?

        evaluation.with_lock do
          return unless evaluation.queued?

          evaluation.update!(status: "running", execute_started_at: Time.current, execution_heartbeat_at: Time.current)
        end

        result = ExecuteReviewer.call(evaluation: evaluation)
        CompileReport.call(evaluation: evaluation) if result.success? && evaluation.runs.exists?
      rescue StandardError => error
        record_failure(evaluation, error)
        raise
      end

      private

      def record_failure(evaluation, error)
        return unless evaluation

        evaluation.with_lock do
          status = evaluation.runs.where.not(verdict: "not_evaluated").exists? ? "partial" : "failed"
          evaluation.update!(status:, last_failure_reason: error.message.truncate(500), execution_heartbeat_at: Time.current)
        end
        CompileReport.call(evaluation: evaluation) if evaluation.runs.exists?
      end
    end
  end
end
