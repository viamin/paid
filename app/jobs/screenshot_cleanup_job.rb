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
    return unless Screenshots::Storage.configured?

    storage = Screenshots::Storage.new
    deleted_count = storage.cleanup_old_screenshots(retention_days: retention_days)

    Rails.logger.info(
      message: "screenshots.cleanup_completed",
      deleted_count: deleted_count,
      retention_days: retention_days
    )
  end
end
