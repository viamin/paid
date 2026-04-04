# frozen_string_literal: true

# Configure GoodJob worker pool, queue priorities, and cron schedule.
#
# Queue priority order (highest to lowest):
#   1. default     — core business logic (run queue processing, workflow health, etc.)
#   2. maintenance — cleanup, reconciliation, recovery (can tolerate brief delays)
#   3. metrics     — telemetry and analytics (deferrable under load)
#   4. knowledge   — embedding and indexing (CPU-intensive, bursty)
#   5. low_priority — dashboard broadcasts, delayed feedback, non-urgent batch work
#
# Thread allocation (default total: 10 threads):
#   - default:3     — reserves 3 threads for critical work
#   - maintenance:2  — 2 threads for cleanup/reconciliation
#   - metrics:2      — 2 threads for telemetry collection
#   - knowledge:2    — 2 threads for embedding (CPU-bound)
#   - low_priority:1 — 1 thread for non-urgent work
#
# See docs/WORKER_POOL_TUNING.md for deployment sizing guidance.
Rails.application.configure do
  # Execution mode: async_server runs jobs in the web process (single-server),
  # external runs a separate worker process (multi-server).
  config.good_job.execution_mode = ENV.fetch(
    "GOOD_JOB_EXECUTION_MODE", :async_server
  ).to_sym

  # Worker thread pool size. Each thread holds one DB connection, so this
  # must not exceed the DB_POOL setting (default 20). The per-queue thread
  # limits below carve this pool into priority bands so high-priority work
  # is never starved by bulk low-priority jobs.
  config.good_job.max_threads = Integer(ENV.fetch("GOOD_JOB_MAX_THREADS", "10"))

  # Queue string with per-queue thread caps (queue_name:max_threads).
  # Semicolons separate independent thread pools; commas share one pool
  # with ordered priority. We use a single shared pool with per-queue caps
  # so idle threads can be borrowed across queues while still reserving
  # capacity for high-priority work.
  config.good_job.queues = ENV.fetch(
    "GOOD_JOB_QUEUES",
    "default:3;maintenance:2;metrics:2;knowledge:2;low_priority:1"
  )

  # How long to wait between polling the DB for new jobs (seconds).
  # Lower values reduce latency for enqueued jobs at the cost of more
  # frequent DB queries. 3s balances responsiveness with DB load.
  config.good_job.poll_interval = Integer(ENV.fetch("GOOD_JOB_POLL_INTERVAL", "3"))

  # Shutdown timeout — how long to wait for in-flight jobs before forcing exit.
  config.good_job.shutdown_timeout = Integer(ENV.fetch("GOOD_JOB_SHUTDOWN_TIMEOUT", "25"))

  config.x.good_job_enable_cron = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch("GOOD_JOB_ENABLE_CRON", "true")
  )
  config.good_job.enable_cron = config.x.good_job_enable_cron

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
      cron: "*/5 * * * *",
      class: "DockerOrphanCleanupJob",
      description: "Remove orphaned Docker containers and volumes"
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
    },
    process_run_queue: {
      cron: "*/5 * * * *",
      class: "ProcessRunQueueJob",
      description: "Process queued agent runs and auto-pick eligible issues"
    },
    service_container_reconciliation: {
      cron: "*/5 * * * *",
      class: "ServiceContainerReconciliationJob",
      description: "Reconcile service container DB records against Docker state"
    },
    knowledge_audit_retention: {
      cron: "0 3 * * *",
      class: "KnowledgeAuditRetentionJob",
      description: "Delete knowledge audit events older than 90 days"
    },
    delayed_human_feedback: {
      # Runs hourly, but the job itself skips runs polled within the last 4 hours
      # (SWEEP_INTERVAL). Hourly ticks prevent the scenario where a poll just
      # after a 4-hour cron tick causes the next tick to defer re-polling to ~8h.
      cron: "0 * * * *",
      class: "DelayedHumanFeedbackCollectionJob",
      description: "Collect delayed human feedback (reactions, reviews) for recent agent runs"
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
