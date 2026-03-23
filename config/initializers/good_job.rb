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
    },
    recover_missing_pull_request_labels: {
      cron: "0 * * * *",
      class: "RecoverMissingPullRequestLabelsJob",
      description: "Re-apply paid-generated labels to Paid-created pull requests"
    },
    models_sync: {
      cron: "0 0 * * *",
      class: "ModelsSyncJob",
      description: "Seed/update LlmModel records from known models list"
    },
    ab_test_analysis: {
      cron: "0 */4 * * *",
      class: "AbTestAnalysisCheckJob",
      description: "Check running A/B tests for auto-completion"
    }
  }
end

# Run orphan cleanup once at startup to catch resources leaked while the app was down.
# Only enqueue from the server process (not console, rake, or tests) to avoid
# duplicate startup enqueues across processes. The job's enqueue_limit: 1
# provides a secondary guard.
Rails.application.config.after_initialize do
  next unless Rails.application.config.good_job.enable_cron
  next unless defined?(Rails::Server) || ENV["GOOD_JOB_EXECUTION_MODE"] == "async_server"

  DockerOrphanCleanupJob.perform_later
end
