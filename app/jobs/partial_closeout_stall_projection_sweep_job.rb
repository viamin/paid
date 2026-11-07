# frozen_string_literal: true

# Self-healing sweep for the persisted partial-closeout stall projection
# (RDR-081): compares each enrolled project's admission-input watermark with
# its checkpoint and enqueues a recomputation for every project whose inputs
# drifted, plus every enrolled project without a successful checkpoint — so a
# missed trigger, an interrupted initial backfill, or a fresh enablement
# converges instead of stranding a stall.
# @spec PARTIAL-CLOSEOUT-042
class PartialCloseoutStallProjectionSweepJob < ApplicationJob
  queue_as :maintenance

  def perform
    Project.where(active: true).includes(account: :tenant_setting).find_each do |project|
      next unless Issues::StalledCloseoutProjection.enabled?(project)
      next unless Issues::StalledCloseoutProjection.due?(project)

      PartialCloseoutStallProjectionJob.perform_later(project.id)
    end
  end
end
