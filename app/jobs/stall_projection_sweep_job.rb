# frozen_string_literal: true

# Compares each enrolled project's admission-relevant inputs with its stall
# projection checkpoint's watermark and schedules a recomputation for every
# project whose inputs changed (RDR-081). Projects without a successful
# checkpoint are always due, so a missed trigger or an interrupted initial
# backfill self-heals on the next sweep instead of stranding a stall.
# @spec PARTIAL-CLOSEOUT-042
class StallProjectionSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    enqueue_limit: 1,
    perform_limit: 1,
    key: "stall_projection_sweep"
  )

  def perform
    scheduled = 0
    Project.active.includes(account: :tenant_setting, created_by: :user_setting).find_each do |project|
      next unless Issues::StalledCloseoutProjection.enabled?(project)
      next unless Issues::StalledCloseoutProjection.due?(project)

      Issues::StalledCloseoutProjection.schedule_recompute(project)
      scheduled += 1
    end
    Rails.logger.info(message: "partial_closeout.stall_projection_sweep_completed", scheduled_recomputations: scheduled)
  end
end
