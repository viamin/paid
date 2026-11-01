# frozen_string_literal: true

# Periodic job to confirm cycle repairs once they've been synchronized.
# Runs as a bounded maintenance task to check all pending_sync repairs across
# the system and transition them to confirmed once the repairs are observed
# in the synchronized dependency graph.
class CycleRepairSyncConfirmationJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "cycle_repair_sync_confirmation")

  def perform
    Account.find_each do |account|
      result = CycleBreakers::ConfirmSync.call(account: account)
      log_result(account, result) if result.confirmed_count > 0 || result.failed_count > 0
    rescue StandardError => error
      Rails.logger.error(
        message: "cycle_repair_sync_confirmation.failed",
        account_id: account.id,
        error_class: error.class.name,
        error: error.message
      )
    end
  end

  private

  def log_result(account, result)
    Rails.logger.info(
      message: "cycle_repair_sync_confirmation.completed",
      account_id: account.id,
      confirmed_count: result.confirmed_count,
      failed_count: result.failed_count,
      stale_count: result.stale_count
    )
  end
end
