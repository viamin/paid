# frozen_string_literal: true

# Requeues workers lost after their last durable case heartbeat. Completed case
# rows are immutable spending boundaries, so recovery only retries gaps.
# @spec INTENT-CONFORMANCE-ROLLOUT-007
class RecoverShadowEvaluationExecutionsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance
  good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "recover-shadow-evaluation-executions"

  STALE_AFTER = 15.minutes

  def perform
    TenantContext.with_system_access do
      IntentConformanceShadowEvaluation.where(status: "running").where("execution_heartbeat_at < ?", STALE_AFTER.ago).find_each do |evaluation|
        evaluation.update!(status: "queued", last_failure_reason: "worker interrupted; reviewer execution recovered")
        ShadowEvaluationReviewerJob.perform_later(evaluation.id)
      end
    end
  end
end
