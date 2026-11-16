# frozen_string_literal: true

# Periodic safety net for the persisted partial-closeout stall projection
# (RDR-081 Option B): recomputes every rollout-enabled project whose
# admission-relevant inputs moved past its checkpoint watermark, and any
# enabled project without a successful checkpoint. Direct triggers cover
# the frequent transitions; this sweep self-heals a missed trigger or an
# interrupted initial backfill so no stall is stranded.
# @spec PARTIAL-CLOSEOUT-042
class StalledCloseoutProjectionSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  BATCH_SIZE = 200

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "stalled_closeout_projection_sweep"
  )

  def perform
    TenantContext.with_system_access do
      Project.active.includes(account: :tenant_setting).find_in_batches(batch_size: BATCH_SIZE) do |batch|
        batch.each do |project|
          next unless Issues::StalledCloseoutProjection.enabled?(project)

          Issues::StalledCloseoutProjection.schedule(project) if Issues::StalledCloseoutProjection.due?(project)
        end
      end
    end
  end
end
