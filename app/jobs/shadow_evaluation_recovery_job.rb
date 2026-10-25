# frozen_string_literal: true

# Re-enqueues a worker whose process died after marking an evaluation running.
# The per-case records make this safe: ExecuteReviewer skips evaluated cases.
class ShadowEvaluationRecoveryJob < ApplicationJob # @spec INTENT-CONFORMANCE-ROLLOUT-011
  include GoodJob::ActiveJobExtensions::Concurrency

  STALE_AFTER = 25.minutes

  queue_as :maintenance
  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "shadow_evaluation_recovery")

  def perform
    stale_evaluations.find_each do |evaluation|
      recovery = claim_recovery(evaluation)
      ExecuteReviewerJob.perform_later(recovery.project_id, recovery.id) if recovery
    end
  end

  private

  def stale_evaluations
    IntentConformanceShadowEvaluation.where(status: "running")
      .where("execution_heartbeat_at < ?", STALE_AFTER.ago)
  end

  def claim_recovery(evaluation)
    evaluation.with_lock do
      return unless evaluation.running? && evaluation.execution_heartbeat_at&.<(STALE_AFTER.ago)

      evaluation.update!(status: "queued", last_failure_reason: "execution worker interrupted; resumed from durable case evidence",
        execution_heartbeat_at: Time.current)
      evaluation
    end
  end
end
