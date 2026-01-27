# Configure GoodJob cron schedule. Enable cron with GOOD_JOB_ENABLE_CRON=true.
Rails.application.configure do
  config.good_job.enable_cron = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch("GOOD_JOB_ENABLE_CRON", "false")
  )

  config.good_job.cron = {
    prompt_evolution: {
      cron: "0 2 * * *",
      class: "PromptEvolutionJob"
    },
    disk_cleanup: {
      cron: "0 * * * *",
      class: "DiskCleanupJob"
    },
    worktree_cleanup: {
      cron: "0 */6 * * *",
      class: "WorktreeOrphanCleanupJob"
    },
    container_cleanup: {
      cron: "*/30 * * * *",
      class: "ContainerCleanupJob"
    },
    log_retention: {
      cron: "0 3 * * *",
      class: "LogRetentionJob"
    },
    orphan_cleanup: {
      cron: "0 * * * *",
      class: "OrphanWorktreeCleanupJob"
    }
  }
end
