# frozen_string_literal: true

# Requeues evaluations whose worker disappeared after accepting work. The
# execution service preserves evaluated case rows, so recovery does not spend
# them again.
# @spec INTENT-CONFORMANCE-ROLLOUT-010
class IntentConformanceShadowEvaluationRecoveryJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(total_limit: 1)

  def perform
    TenantContext.with_system_access do
      stale_evaluations.find_each do |evaluation|
        IntentConformance::ShadowEvaluation::ScheduleExecution.call(evaluation: evaluation)
      end
    end
  end

  private

  def stale_evaluations
    IntentConformanceShadowEvaluation.where(status: %w[queued running])
      .where("execution_heartbeat_at IS NULL OR execution_heartbeat_at < ?", IntentConformanceShadowEvaluation::EXECUTION_STALE_AFTER.ago)
  end
end
