# frozen_string_literal: true

# Runs one frozen shadow evaluation outside the request lifecycle. The durable
# state on IntentConformanceShadowEvaluation is the source of truth for retry,
# cancellation, progress, and worker-loss recovery.
class ExecuteReviewerJob < ApplicationJob # @spec INTENT-CONFORMANCE-ROLLOUT-011
  include GoodJob::ActiveJobExtensions::Concurrency

  class ExecutionError < StandardError; end

  queue_as :low_priority
  self.perform_timeout = 20.minutes
  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1,
    key: -> { "shadow_evaluation_#{arguments.second}" })
  retry_on ExecutionError, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.fail_execution(error)
  end
  discard_on ActiveRecord::RecordNotFound

  def perform(project_id, evaluation_id)
    evaluation = nil
    evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
    return if evaluation.project_id != project_id
    return if cancelled_before_start?(evaluation)

    return unless claim!(evaluation)
    result = IntentConformance::ShadowEvaluation::ExecuteReviewer.call(evaluation: evaluation)
    return if result.success?
    return if result.error.include?("already in progress")

    raise ExecutionError, result.error
  ensure
    compile_available_report(evaluation)
  end

  def fail_execution(error)
    evaluation = IntentConformanceShadowEvaluation.find_by(id: arguments.second)
    return unless evaluation

    evaluation.update!(status: "failed", last_failure_reason: error.message, execution_heartbeat_at: Time.current)
    compile_available_report(evaluation)
  end

  private

  def claim!(evaluation)
    evaluation.with_lock do
      return false if evaluation.cancelled?

      evaluation.update!(status: "running", execute_started_at: Time.current,
        execution_heartbeat_at: Time.current, execution_attempts: evaluation.execution_attempts + 1)
      true
    end
  end

  def cancelled_before_start?(evaluation)
    return false unless evaluation.cancelled?

    compile_available_report(evaluation)
    true
  end

  def compile_available_report(evaluation)
    return unless evaluation&.runs&.exists?

    IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation)
  end
end
