# frozen_string_literal: true

# Configure GoodJob cron schedule. Disable cron with GOOD_JOB_ENABLE_CRON=false.
Rails.application.configure do
  config.good_job.enable_cron = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch("GOOD_JOB_ENABLE_CRON", "true")
  )

  config.good_job.cron = {
    worktree_cleanup: {
      cron: "0 */6 * * *",
      class: "WorktreeOrphanCleanupJob"
    },
    poll_workflow_health_check: {
      cron: "*/5 * * * *",
      class: "PollWorkflowHealthCheckJob"
    },
    stale_run_detector: {
      cron: "*/5 * * * *",
      class: "StaleRunDetectorJob"
    }
  }
end
