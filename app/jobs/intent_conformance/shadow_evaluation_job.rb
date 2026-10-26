# frozen_string_literal: true

module IntentConformance
  # Executes the persisted shadow evaluation after an operator has queued it.
  # Every attempt resumes from durable case rows, so GoodJob redelivery and a
  # released advisory lock cannot repeat an evaluated case's provider spend.
  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  class ShadowEvaluationJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :low_priority
    self.perform_timeout = 15.minutes
    good_job_control_concurrency_with(total_limit: 1,
      key: -> { "intent_conformance_shadow_evaluation_#{arguments.second}" })
    discard_on ActiveRecord::RecordNotFound

    def perform(project_id, evaluation_id)
      evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
      return unless evaluation.project_id == project_id
      return if evaluation.cancelled? || evaluation.completed?

      evaluation.update!(execution_attempts: evaluation.execution_attempts + 1)
      result = ShadowEvaluation::ExecuteReviewer.call(evaluation: evaluation)
      ShadowEvaluation::CompileReport.call(evaluation: evaluation.reload) if evaluation.runs.exists?
      return if result.success?
      return if evaluation.reload.cancelled?
      return if result.error.include?("already in progress")

      evaluation.update!(status: "failed", last_failure_reason: result.error)
    rescue StandardError => error
      recover(evaluation_id, error)
      raise
    end

    private

    def recover(evaluation_id, error)
      evaluation = IntentConformanceShadowEvaluation.find_by(id: evaluation_id)
      return unless evaluation && !evaluation.cancelled? && !evaluation.completed?

      evaluation.update!(status: evaluation.runs.exists? ? "partial" : "failed", last_failure_reason: error.message)
    end
  end
end
