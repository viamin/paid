# frozen_string_literal: true

module IntentConformance
  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  class ShadowEvaluationExecutionJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :low_priority
    self.perform_timeout = 30.minutes
    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1,
      key: -> { "shadow-evaluation-#{arguments.first}" })
    discard_on ActiveRecord::RecordNotFound

    def perform(evaluation_id)
      evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
      return unless claim!(evaluation)

      result = ShadowEvaluation::ExecuteReviewer.call(evaluation:, cancelled: -> { cancellation_requested?(evaluation) })
      ShadowEvaluation::CompileReport.call(evaluation:) if result.success? && evaluation.runs.exists?
    rescue StandardError => error
      mark_failed(evaluation, error)
      raise
    end

    private

    def claim!(evaluation)
      evaluation.with_lock do
        return false if evaluation.cancelled? || evaluation.completed?
        if evaluation.cancellation_requested_at.present?
          evaluation.update!(status: "cancelled")
          return false
        end
        return false unless evaluation.queued? || evaluation.running?

        evaluation.update!(status: "running", execute_started_at: evaluation.execute_started_at || Time.current)
        true
      end
    end

    def cancellation_requested?(evaluation)
      evaluation.reload.cancellation_requested_at.present?
    end

    def mark_failed(evaluation, error)
      return unless evaluation
      return if evaluation.cancelled?

      evaluation.update!(status: evaluation.runs.exists? ? "partial" : "failed", last_failure_reason: error.message)
    end
  end
end
