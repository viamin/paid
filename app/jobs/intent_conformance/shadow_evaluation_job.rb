# frozen_string_literal: true

module IntentConformance
  # Durable, tenant-scoped worker for a frozen shadow evaluation. The
  # evaluator's advisory lock still prevents duplicated provider spend if a
  # retry overlaps a delayed worker.
  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  class ShadowEvaluationJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :low_priority
    self.perform_timeout = 30.minutes
    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1,
      key: -> { "intent-conformance-shadow-evaluation-#{arguments.second}" })
    discard_on ActiveRecord::RecordNotFound

    def perform(project_id, evaluation_id)
      evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
      return if evaluation.project_id != project_id || evaluation.cancelled? || evaluation.completed?

      result = ShadowEvaluation::ExecuteReviewer.call(evaluation: evaluation)
      ShadowEvaluation::CompileReport.call(evaluation: evaluation) if result.success?
      return if result.success?

      evaluation.update!(status: "failed", last_failure_reason: result.error) unless evaluation.reload.cancelled?
    rescue StandardError => error
      evaluation&.update!(status: "failed", last_failure_reason: error.message) unless evaluation&.cancelled?
      raise
    end
  end
end
