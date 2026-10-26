# frozen_string_literal: true

module IntentConformance
  # Executes one durable, cooperative shadow-evaluation operation. Replayed
  # jobs are harmless: evaluated cases are never sent to the reviewer again.
  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  class ShadowEvaluationJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :default
    retry_on ApplicationJob::PerformTimeoutError, wait: :polynomially_longer, attempts: 3
    discard_on ActiveRecord::RecordNotFound

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: -> { "intent_conformance_shadow_evaluation_#{arguments.first}" }
    )

    def perform(evaluation_id)
      evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
      return unless evaluation.queued? || evaluation.running?
      return if evaluation.execution_cancel_requested?

      IntentConformance::ShadowEvaluation::ExecuteReviewer.call(evaluation:)
      IntentConformance::ShadowEvaluation::CompileReport.call(evaluation:)
    rescue StandardError => e
      evaluation&.update!(status: "partial", last_failure_reason: e.message, execution_heartbeat_at: Time.current)
      raise
    end
  end
end
