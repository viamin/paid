# frozen_string_literal: true

# Durable boundary for slow reviewer calls. Case evidence is saved by
# ExecuteReviewer after every provider response, so a retry/resume only spends
# cases without an evaluated verdict.
# @spec INTENT-CONFORMANCE-ROLLOUT-010
class IntentConformanceShadowEvaluationExecutionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    enqueue_limit: 1,
    key: -> { "intent_conformance_shadow_evaluation_#{arguments.first}" }
  )

  def perform(evaluation_id, execution_attempt)
    evaluation = IntentConformanceShadowEvaluation.find_by(id: evaluation_id)
    return unless evaluation
    return unless evaluation.execution_attempt == execution_attempt

    return if evaluation.cancelled?

    result = IntentConformance::ShadowEvaluation::ExecuteReviewer.call(
      evaluation: evaluation,
      cancellation_check: -> { evaluation.reload.cancellation_requested_at.present? }
    )
    finish(evaluation, execution_attempt, result)
  rescue StandardError => error
    fail(evaluation, execution_attempt, error)
    raise
  end

  private

  def finish(evaluation, execution_attempt, result)
    return unless current_attempt?(evaluation, execution_attempt)

    unless result.success?
      return if result.error.include?("already in progress")

      evaluation.update!(status: "failed", last_failure_reason: result.error, execution_heartbeat_at: Time.current)
      return
    end

    IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation)
  end

  def fail(evaluation, execution_attempt, error)
    return unless evaluation && current_attempt?(evaluation, execution_attempt)

    status = evaluation.runs.exists? ? "partial" : "failed"
    evaluation.update!(status: status, last_failure_reason: error.message, execution_heartbeat_at: Time.current)
  end

  def current_attempt?(evaluation, execution_attempt)
    evaluation.reload.execution_attempt == execution_attempt
  end

  def tenant_account
    TenantContext.with_system_access do
      IntentConformanceShadowEvaluation.includes(:project).find_by(id: arguments.first)&.project&.account
    end
  end
end
