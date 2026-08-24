# frozen_string_literal: true

class ScreenshotCleanupJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "screenshot_cleanup"
  )

  # Deletes screenshots older than the configured retention period.
  #
  # @param retention_days [Integer] Number of days to retain screenshots (default: 30)
  def perform(retention_days: 30)
    prune_page_load_measurements(retention_days)

    return unless Screenshots::Storage.configured?

    storage = Screenshots::Storage.new
    deleted_count = storage.cleanup_old_screenshots(retention_days: retention_days)

    Rails.logger.info(
      message: "screenshots.cleanup_completed",
      deleted_count: deleted_count,
      retention_days: retention_days
    )
  end

  private

  # The ledger describes artifacts that expire on this same schedule; keeping
  # measurements past their screenshots leaves history no one can look at.
  # @spec PAGE-LOAD-LEDGER-004
  def prune_page_load_measurements(retention_days)
    deleted = TenantContext.with_system_access do
      PageLoadMeasurement.prune_older_than(retention_days.days.ago)
    end

    Rails.logger.info(
      message: "page_load.measurements_pruned",
      deleted_count: deleted,
      retention_days: retention_days
    )
  end
end
