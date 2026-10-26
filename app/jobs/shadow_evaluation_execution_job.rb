# frozen_string_literal: true

# Runs one durable shadow-evaluation request outside the HTTP lifecycle.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
class ShadowEvaluationExecutionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :low_priority
  self.perform_timeout = 30.minutes
  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 2,
    key: -> { "shadow_evaluation_execution_#{arguments.first}" })
  discard_on ActiveRecord::RecordNotFound

  def perform(evaluation_id)
    evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
    return if evaluation.cancelled? || evaluation.completed?

    result = IntentConformance::ShadowEvaluation::ExecuteReviewer.call(evaluation: evaluation)
    IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation) if evaluation.reload.runs.exists?
    fail_execution(evaluation, result.error) unless result.success?
  rescue StandardError => error
    fail_execution(evaluation, error.message) if evaluation
    raise
  end

  private

  def fail_execution(evaluation, reason)
    evaluation.with_lock do
      evaluation.reload
      return if evaluation.cancelled? || evaluation.completed?

      evaluation.update!(status: evaluation.runs.exists? ? "partial" : "failed", last_failure_reason: reason)
    end
  end
end
