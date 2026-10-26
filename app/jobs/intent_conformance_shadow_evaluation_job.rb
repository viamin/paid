# frozen_string_literal: true

# Background boundary for an Inbox-linked shadow evaluation. It reloads the
# record so each perform observes cancellation and preserves completed cases
# when a retry/resume is queued.
# @spec INTENT-CONFORMANCE-ROLLOUT-011 @spec INTENT-CONFORMANCE-ROLLOUT-013
class IntentConformanceShadowEvaluationJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(evaluation_id)
    evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
    return if evaluation.cancelled?
    return unless evaluation.queued? || evaluation.running? || evaluation.partial? || evaluation.failed? || evaluation.frozen?

    result = IntentConformance::ShadowEvaluation::ExecuteReviewer.call(evaluation:)
    IntentConformance::ShadowEvaluation::CompileReport.call(evaluation:) if evaluation.reload.runs.exists?
    raise ExecutionFailed, result.error unless result.success?
  rescue StandardError => error
    mark_failed(evaluation_id, error)
    raise
  end

  private

  class ExecutionFailed < StandardError; end

  def mark_failed(evaluation_id, error)
    evaluation = IntentConformanceShadowEvaluation.find_by(id: evaluation_id)
    return unless evaluation && evaluation.running?

    evaluation.update!(status: "failed", last_failure_reason: error.message.to_s.truncate(500))
  end
end
