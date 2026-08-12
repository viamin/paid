# frozen_string_literal: true

module Paid
  module GoodJobConfig
    module_function

    def execution_mode(env = ENV)
      env.fetch("GOOD_JOB_EXECUTION_MODE", :async_server).to_sym
    end

    def max_threads(env = ENV)
      resolve_from_db("good_job_max_threads", env_key: "GOOD_JOB_MAX_THREADS", env: env, default: 11)
    end

    def queues(env = ENV)
      resolve_from_db("good_job_queues", env_key: "GOOD_JOB_QUEUES", env: env,
        default: "default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1")
    end

    def resolve_from_db(key, env_key:, env:, default:)
      TenantSetting.resolve_worker_setting(key, env_key: env_key, env: env, default: default)
    rescue NameError
      resolve_from_env(env_key, env:, default:)
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid, ArgumentError
      default
    end

    def resolve_from_env(env_key, env:, default:)
      fallback = env.fetch(env_key, nil)
      return default unless fallback
      begin
        Integer(fallback)
      rescue ArgumentError
        fallback
      end
    end

    def poll_interval(env = ENV)
      Integer(env.fetch("GOOD_JOB_POLL_INTERVAL", "3"))
    end

    def shutdown_timeout(env = ENV)
      Integer(env.fetch("GOOD_JOB_SHUTDOWN_TIMEOUT", "25"))
    end

    def enable_cron(env = ENV)
      ActiveModel::Type::Boolean.new.cast(env.fetch("GOOD_JOB_ENABLE_CRON", "true"))
    end

    def bootstrap_startup_jobs?(env = ENV, server_process: defined?(Rails::Server))
      server_process || bootstrap_on_start?(env)
    end

    def bootstrap_on_start?(env = ENV)
      ActiveModel::Type::Boolean.new.cast(env.fetch("GOOD_JOB_BOOTSTRAP_ON_START", "false"))
    end
  end
end

# @spec RAILS-CONTROL-PLANE-003
# @spec TEMPORAL-ORCHESTRATION-003
# Configure GoodJob worker pools, queue roles, and cron schedule.
#
# Queue priority order (highest to lowest):
#   1. default     — core business logic (run queue processing, workflow health, etc.)
#   2. maintenance — cleanup, reconciliation, recovery (can tolerate brief delays)
#   3. metrics     — telemetry and analytics (deferrable under load)
#   4. knowledge   — embedding and indexing (CPU-intensive, bursty)
#   5. low_priority — dashboard broadcasts, delayed feedback, non-urgent batch work
#
# Thread allocation (default total: 11 threads):
#   - default:3     — reserves 3 threads for critical work
#   - maintenance:2  — 2 threads for cleanup/reconciliation
#   - metrics:2      — 2 threads for telemetry collection
#   - knowledge:3    — 3 threads for collection and embedding (CPU-bound, bursty)
#   - low_priority:1 — 1 thread for non-urgent work
#
# See docs/WORKER_POOL_TUNING.md for deployment sizing guidance.
Rails.application.configure do
  config.good_job.execution_mode = Paid::GoodJobConfig.execution_mode

  config.good_job.cleanup_preserved_jobs_before_seconds_ago = 1.day
  # Cron scheduling is safe to enable on multiple hosts: GoodJob 4.x stamps
  # every cron enqueue with a (cron_key, cron_at) pair guarded by the unique
  # index `index_good_jobs_on_cron_key_and_cron_at_cond`, so a duplicate tick
  # from a second host enqueues nothing. GOOD_JOB_ENABLE_CRON=false remains an
  # available optimization for hosts that should skip scheduler polling
  # entirely (see docs/SCALING.md § Horizontal Scaling).
  config.x.good_job_enable_cron = Paid::GoodJobConfig.enable_cron
  config.good_job.enable_cron = config.x.good_job_enable_cron

  # Keep frequent maintenance jobs staggered across the 5-minute window. Several
  # of these jobs scan projects, containers, queues, or external services; if
  # they all enqueue on :00/:05/:10 boundaries, the in-process async_server
  # worker can see a short memory spike large enough to OOM the Rails process.
  config.good_job.cron = {
    worktree_cleanup: {
      cron: "0 */6 * * *",
      class: "WorktreeOrphanCleanupJob"
    },
    poll_workflow_health_check: {
      cron: "1-59/5 * * * *",
      class: "PollWorkflowHealthCheckJob"
    },
    stale_run_detector: {
      cron: "2-59/5 * * * *",
      class: "StaleRunDetectorJob"
    },
    docker_orphan_cleanup: {
      cron: "3-59/5 * * * *",
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
    free_models_sync: {
      cron: "15 0 * * *",
      class: "FreeModels::SyncJob",
      queue: "maintenance",
      description: "Sync OpenRouter free models into the LlmModel catalog"
    },
    model_health_check: {
      cron: "0 5 * * *",
      class: "ModelHealthCheckJob",
      queue: "maintenance",
      description: "Detect provider model catalog drift and broken runner models; file a self-repo issue"
    },
    account_health_check_sweep: {
      cron: "30 5 * * *",
      class: "AccountHealthCheckSweepJob",
      queue: "maintenance",
      description: "Daily sweep recomputing project configuration health checks and refreshing the cached results"
    },
    ab_test_analysis: {
      cron: "0 */4 * * *",
      class: "AbTestAnalysisCheckJob",
      description: "Check running A/B tests for auto-completion"
    },
    process_run_queue: {
      cron: "*/5 * * * *",
      class: "ProcessRunQueueJob",
      description: "Process queued agent runs"
    },
    auto_pick_queue_backfill: {
      cron: "0 * * * *",
      class: "AutoPickQueueBackfillJob",
      description: "Backfill eager auto-pick queue seeding for already-enabled projects"
    },
    auto_pick_eligibility_sweep: {
      cron: "7-59/15 * * * *",
      class: "AutoPickEligibilitySweepJob",
      description: "Periodic re-evaluation of all open issues for auto-pick eligibility"
    },
    analyze_issue_followup_backfill: {
      cron: "15 * * * *",
      class: "AnalyzeIssueFollowupBackfillJob",
      description: "Backfill follow-up runs for legacy analyzed issues"
    },
    service_container_reconciliation: {
      cron: "1-59/5 * * * *",
      class: "ServiceContainerReconciliationJob",
      description: "Reconcile service container DB records against Docker state"
    },
    container_pool_replenishment: {
      cron: "4-59/5 * * * *",
      class: "PoolReplenishmentJob",
      description: "Maintain warm agent container pool"
    },
    knowledge_audit_retention: {
      cron: "0 3 * * *",
      class: "KnowledgeAuditRetentionJob",
      description: "Delete knowledge audit events older than 90 days"
    },
    audit_event_retention: {
      cron: "0 4 * * *",
      class: "AuditEventRetentionJob",
      description: "Delete account audit events older than 365 days"
    },
    screenshot_cleanup: {
      cron: "30 3 * * *",
      class: "ScreenshotCleanupJob",
      description: "Delete uploaded screenshots older than the retention window"
    },
    orphan_branch_reaper: {
      cron: "0 * * * *",
      class: "OrphanBranchReaperJob",
      description: "Delete remote branches orphaned by retried/timeout/failed agent runs"
    },
    prompt_evolution: {
      cron: "0 3 * * 1",
      class: "PromptEvolutionJob",
      description: "Trigger prompt evolution workflows for eligible prompts (weekly)"
    },
    style_guide_evolution: {
      cron: "30 3 * * 1",
      class: "StyleGuideEvolutionJob",
      description: "Trigger style guide evolution workflows for eligible guides (weekly)"
    },
    delayed_human_feedback: {
      # Runs hourly, but the job itself skips runs polled within the last 12 hours
      # (SWEEP_INTERVAL). Hourly ticks prevent the scenario where a poll just
      # after a 12-hour cron tick causes the next tick to defer re-polling to ~24h.
      cron: "0 * * * *",
      class: "DelayedHumanFeedbackCollectionJob",
      description: "Collect delayed human feedback (reactions, reviews) for recent agent runs"
    },
    queue_monitor: {
      cron: "2-59/5 * * * *",
      class: "QueueMonitorJob",
      description: "Monitor queue depths and alert when thresholds are exceeded"
    },
    notifications_check_runner_quotas: {
      cron: "3-59/5 * * * *",
      class: "Notifications::CheckRunnerQuotasJob",
      description: "Publish runner quota exhaustion notifications"
    },
    runner_quota_balance: {
      cron: "9-59/15 * * * *",
      class: "RunnerQuotaBalanceJob",
      description: "Recalculate automated runner weights from remaining quota"
    },
    runner_refresh_quota_snapshots: {
      cron: "12-59/15 * * * *",
      class: "Runners::RefreshQuotaSnapshotsJob",
      description: "Proactively refresh upstream quota snapshots for all runners (RDR-025a)"
    },
    llm_output_metric_feedback: {
      cron: "0 */6 * * *",
      class: "LlmOutputMetricFeedbackCollectionJob",
      description: "Collect feedback for LLM output metrics (decision records)"
    },
    github_token_health_check: {
      cron: "0 6 * * *",
      class: "GithubTokenHealthCheckJob",
      description: "Validate all active GitHub tokens and flag revoked/expired ones"
    },
    claude_auth_health_check: {
      cron: "0 */4 * * *",
      class: "ClaudeAuthHealthCheckJob",
      description: "Check Claude subscription auth health and flag expired or expiring credentials"
    },
    claude_credential_keep_warm: {
      cron: "0 */4 * * *",
      class: "ClaudeCredentialKeepWarmJob",
      description: "Refresh host-forwarded Claude subscription credentials before expiry (RDR-041 Phase 3)"
    },
    chat_idle_reaper: {
      cron: "4-59/5 * * * *",
      class: "ChatSessions::IdleReaperJob",
      description: "Close idle chat sessions past their timeout"
    },
    preview_session_expiry_reaper: {
      cron: "*/5 * * * *",
      class: "PreviewSessions::ExpireJob",
      description: "Stop preview sessions whose TTL has passed so tunnel ports return to the pool (RDR-045)"
    },
    knowledge_evolution: {
      cron: "0 3 * * 2",
      class: "KnowledgeEvolutionJob",
      description: "Analyze knowledge gaps and recommend collector improvements (weekly)"
    },
    coordination_policy_evolution: {
      cron: "0 4 * * 3",
      class: "CoordinationPolicyEvolutionJob",
      description: "Generate coordination policy candidates for decomposition, recovery, and escalation (weekly)"
    },
    coordination_experiment_resolution: {
      cron: "0 */4 * * *",
      class: "CoordinationExperimentResolutionJob",
      description: "Check running coordination experiments for promotion readiness and mark winners"
    },
    agent_run_pattern_detector: {
      cron: "11-59/15 * * * *",
      class: "AgentRunPatternDetectorJob",
      description: "Detect goal-level failure patterns in agent runs and notify"
    },
    remediation_decision_outcomes: {
      cron: "13-59/15 * * * *",
      class: "RemediationDecisionOutcomeJob",
      description: "Evaluate outcomes for auto-applied self-heal remediations"
    },
    billing_period_management: {
      cron: "15 2 * * *",
      class: "BillingPeriodManagementJob",
      description: "Close due billing periods, issue invoices, and open the next active period"
    },
    temporal_patch_guard_sweep: {
      cron: "0 4 1 */3 *",
      class: "TemporalPatchGuardSweepJob",
      description: "Audit Temporal workflow patch guards against oldest running executions (quarterly)"
    },
    scheduled_mutation_sweep: {
      cron: "17 9 * * *",
      class: "ScheduledMutationSweepJob",
      description: "Run nightly full-suite mutation sweeps for opted-in Ruby projects"
    },
    dispatch_circuit_breaker_recovery: {
      cron: "1-59/5 * * * *",
      class: "DispatchCircuitBreakerRecoveryJob",
      description: "Check open dispatch circuit breakers for recovery to half_open"
    }
  }
end

# TenantSetting-dependent config resolved in to_prepare so that the
# autoloaded TenantSetting model is fully available (not during boot).
# to_prepare runs after after_initialize on first boot, and again on
# each code reload in development. GoodJob reads these settings when
# the scheduler starts (after full boot), so the values are available.
Rails.application.config.to_prepare do
  Rails.application.config.good_job.max_threads = Paid::GoodJobConfig.max_threads
  Rails.application.config.good_job.queues = Paid::GoodJobConfig.queues
  Rails.application.config.good_job.poll_interval = Paid::GoodJobConfig.poll_interval
  Rails.application.config.good_job.shutdown_timeout = Paid::GoodJobConfig.shutdown_timeout
end

# Run orphan cleanup once at startup to catch resources leaked while the app was down.
# Only enqueue from the server process (not console, rake, or tests) to avoid
# duplicate startup enqueues across processes. The job's enqueue_limit: 1
# provides a secondary guard.
Rails.application.config.after_initialize do
  next unless Rails.application.config.good_job.enable_cron
  next unless Paid::GoodJobConfig.bootstrap_startup_jobs?

  "DockerOrphanCleanupJob".constantize.perform_later
  "AutoPickQueueBackfillJob".constantize.perform_later
  "AnalyzeIssueFollowupBackfillJob".constantize.perform_later
  "PoolReplenishmentJob".constantize.perform_later if "Containers::PoolManager".constantize.enabled?
end
