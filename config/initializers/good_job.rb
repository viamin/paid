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
    },
    docker_orphan_cleanup: {
      cron: "*/15 * * * *",
      class: "DockerOrphanCleanupJob"
    }
  }
end

# Run orphan cleanup once at startup to catch resources leaked while the app was down.
Rails.application.config.after_initialize do
  DockerOrphanCleanupJob.perform_later if Rails.application.config.good_job.enable_cron
end
