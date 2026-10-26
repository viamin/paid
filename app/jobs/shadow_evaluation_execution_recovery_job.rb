# frozen_string_literal: true

# Repairs requests stranded by a worker restart or process death.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
class ShadowEvaluationExecutionRecoveryJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  STALE_AFTER = 35.minutes

  queue_as :maintenance
  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "shadow_evaluation_execution_recovery")

  def perform
    TenantContext.with_system_access do
      stale_evaluations.find_each do |evaluation|
        evaluation.with_lock do
          next unless evaluation.queued? || evaluation.running?
          next unless evaluation.updated_at < STALE_AFTER.ago

          evaluation.update!(status: "queued", execution_enqueued_at: Time.current,
            last_failure_reason: "recovered a stale worker execution")
          ShadowEvaluationExecutionJob.perform_later(evaluation.id)
        end
      end
    end
  end

  private

  def stale_evaluations
    IntentConformanceShadowEvaluation.where(status: %w[queued running]).where("updated_at < ?", STALE_AFTER.ago)
  end
end
