# frozen_string_literal: true

# Background execution of a frozen shadow evaluation's reviewer pass
# (#4642). Enqueued only by IntentConformance::ShadowEvaluation::EnqueueExecution
# and the stalled-execution recovery sweep. The executor's advisory lock
# makes this job (or a duplicate after worker recovery) safe: only the lock
# holder mutates lifecycle state, executed cases are never re-spent, and a
# requested cancellation is honored before the first reviewer invocation.
# Terminal passes compile and attach the report through the existing
# CompileReport service whenever any run exists.
# @spec INTENT-CONFORMANCE-ROLLOUT-007
# @spec INTENT-CONFORMANCE-ROLLOUT-011
class ShadowEvaluationExecuteJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "shadow-evaluation-execute-#{arguments.first}" }
  )

  # Wall-clock backstop for a pass that can block indefinitely on external
  # I/O (30 corpus cases × provider + GitHub calls); interruption is then
  # recorded from persisted evidence and the recovery sweep resumes.
  self.perform_timeout = 2.hours

  def perform(evaluation_id)
    evaluation = IntentConformanceShadowEvaluation.find_by(id: evaluation_id)
    return unless evaluation
    return if evaluation.labeling? || evaluation.status.in?(TERMINAL_STATUSES)

    result = IntentConformance::ShadowEvaluation::ExecuteReviewer.call(evaluation: evaluation)
    return if result.busy? # another worker owns the lifecycle; nothing to change

    unless result.success?
      record_precondition_failure(evaluation, result.error)
      return
    end

    compile_report(evaluation)
  rescue StandardError => error
    record_interruption(evaluation, error)
    raise
  end

  private

  TERMINAL_STATUSES = %w[completed partial failed cancelled].freeze

  # A gate that passed at enqueue time can fail by perform time (e.g. the
  # corpus changed in between): record the failed pass with the reason
  # instead of leaving the evaluation queued forever.
  def record_precondition_failure(evaluation, reason)
    evaluation.update!(status: "failed", last_failure_reason: reason)
    Rails.logger.warn(
      message: "intent_conformance.shadow_evaluation_execute_refused",
      shadow_evaluation_id: evaluation.id,
      project_id: evaluation.project_id,
      reason: reason
    )
  end

  # A killed worker, hung provider, or lost lock must not strand the
  # evaluation as running: the terminal state is recomputed from persisted
  # runs — collected evidence survives as partial (or failed when nothing
  # was evaluated) and the report is compiled from what exists. Re-raise so
  # the job backend still records the failure.
  def record_interruption(evaluation, error)
    evaluation.reload
    return if evaluation.labeling? || evaluation.status.in?(TERMINAL_STATUSES)

    evaluated = evaluation.runs.evaluated.count
    status = evaluated.positive? ? "partial" : "failed"
    evaluation.update!(status: status,
      last_failure_reason: "execution interrupted before completion: #{error.class.name}")
    compile_report(evaluation)
  end

  def compile_report(evaluation)
    return unless evaluation.runs.exists?

    IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation)
  end
end
