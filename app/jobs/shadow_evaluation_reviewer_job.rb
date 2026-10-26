# frozen_string_literal: true

# Durable boundary around external reviewer calls; CLI/API/UI share the same service.
# @spec INTENT-CONFORMANCE-ROLLOUT-007 @spec INTENT-CONFORMANCE-ROLLOUT-009
class ShadowEvaluationReviewerJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default
  good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: -> { "shadow-evaluation-reviewer-#{arguments.first}" }
  discard_on ActiveRecord::RecordNotFound

  def perform(evaluation_id)
    evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
    return if evaluation.cancelled? || evaluation.completed?

    result = IntentConformance::ShadowEvaluation::ExecuteReviewer.call(evaluation:)
    IntentConformance::ShadowEvaluation::CompileReport.call(evaluation:) if evaluation.runs.exists?
    raise result.error unless result.success?
  rescue StandardError => error
    evaluation&.update!(status: "failed", last_failure_reason: error.message, execution_heartbeat_at: Time.current)
    raise
  end

  private

  def tenant_account = IntentConformanceShadowEvaluation.find_by(id: arguments.first)&.project&.account
end
