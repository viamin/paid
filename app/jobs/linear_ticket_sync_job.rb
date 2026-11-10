# frozen_string_literal: true

# Polls enabled account Linear connections at their configured cadence.
class LinearTicketSyncJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance
  self.perform_timeout = 240

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "linear_ticket_sync"
  )

  # @spec UNIFIED-WORK-ITEMS-002 UNIFIED-WORK-ITEMS-009
  def perform
    TrackerConfiguration.enabled.where(tracker_type: "linear", configurable_type: "Account").find_each do |configuration|
      next unless due?(configuration)

      TenantContext.with(configuration.account) do
        project = Project.where(account: configuration.account).find_each.find do |candidate|
          Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(candidate)
        end
        WorkItems::SyncLinear.call(project:) if project
      end
    rescue IssueTrackers::Adapters::Linear::Error => error
      Rails.logger.warn(message: "linear_ticket_sync.failed", account_id: configuration.configurable_id,
        error_class: error.class.name)
    end
  end

  private

  def due?(configuration)
    configuration.last_synced_at.nil? ||
      configuration.last_synced_at <= configuration.sync_interval_seconds.seconds.ago
  end
end
