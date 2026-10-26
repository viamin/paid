# frozen_string_literal: true

# Runs a persisted shadow-evaluation request outside the operator's HTTP
# lifetime. GoodJob's concurrency key and ExecuteReviewer's advisory lock
# jointly prevent duplicate provider spend.
# @spec INTENT-CONFORMANCE-ROLLOUT-007
# @spec INTENT-CONFORMANCE-ROLLOUT-009
class ShadowEvaluationExecutionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :low_priority
  self.perform_timeout = 30.minutes
  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1,
    key: -> { "shadow_evaluation_#{arguments.second}" })
  discard_on ActiveRecord::RecordNotFound

  def perform(project_id, evaluation_id)
    evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
    return unless evaluation.project_id == project_id
    return if evaluation.cancelled? || evaluation.completed?

    result = IntentConformance::ShadowEvaluation::ExecuteReviewer.call(evaluation: evaluation)
    IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation) if result.success? && evaluation.runs.exists?
  rescue StandardError => error
    evaluation&.update!(status: "failed", last_failure_reason: error.message, execution_heartbeat_at: Time.current)
    IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation) if evaluation&.runs&.exists?
    raise
  end
end
