# EARS Specs: Temporal Orchestration

> Testable claims for the implemented Temporal orchestration layer. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r TEMPORAL-ORCHESTRATION-001`).

## Client and Queue Topology

- [x] **TEMPORAL-ORCHESTRATION-001** — The orchestration layer SHALL connect to
  Temporal through the official Ruby SDK and SHALL expose separate poll and
  agent task queues so polling workflows are isolated from agent-execution
  workloads.
  *Tests:* `spec/jobs/knowledge_evolution_job_spec.rb`, `spec/jobs/poll_workflow_health_check_job_spec.rb`.
  *Code:* `Paid.temporal_client`, `Paid.poll_task_queue`, `Paid.agent_task_queue`.

- [x] **TEMPORAL-ORCHESTRATION-011** — When the application's JSON dependency
  requires keyword options, Temporal clients, workers, and replay verification
  SHALL serialize and deserialize `json/plain` payloads with keyword arguments
  and without insecure object additions, so recorded workflow histories remain
  replayable.
  *Tests:* `spec/lib/paid/temporal_data_converter_spec.rb`,
  `spec/temporal/workflow_replay_fixtures_spec.rb`.
  *Code:* `Paid::TemporalDataConverter`, `Paid.temporal_client`,
  `Paid.temporal_worker_client`.

## Worker Resource Sizing

- [x] **TEMPORAL-ORCHESTRATION-013** — When a Temporal worker receives a first
  INT or TERM signal, it SHALL request graceful cancellation outside Ruby's
  signal trap context and remove its readiness marker. A watchdog SHALL force
  exit when cancellation blocks. A repeated signal SHALL remove readiness and
  force exit.
  *Tests:* `spec/lib/paid/temporal_worker_shutdown_spec.rb`.
  *Code:* `Paid::TemporalWorkerShutdown`, `bin/temporal_worker`.

- [x] **TEMPORAL-ORCHESTRATION-002** — The orchestration layer SHALL derive the
  minimum database connection pool for Temporal workers from the selected worker
  mode, activity-slot counts, and heartbeat-thread overhead.
  *Tests:* `spec/lib/paid/temporal_worker_config_spec.rb`.
  *Code:* `Paid::TemporalWorkerConfig`.

- [x] **TEMPORAL-ORCHESTRATION-020** — Temporal activity execution SHALL publish
  coarse worker-ownership observations without exposing activity data or claiming
  to control task admission. The updater SHALL NOT use those observations to
  authorize a worker stop.
  *Tests:* `spec/temporal/activities/base_activity_spec.rb`,
  `spec/lib/paid/worker_readiness_spec.rb`.
  *Code:* `Activities::BaseActivity`, `Paid::WorkerReadiness`.

- [ ] **TEMPORAL-ORCHESTRATION-021** — Before an updater stops a ready Temporal
  worker, it SHALL obtain a quiescence acknowledgement through released public SDK
  slot-supplier contracts that closes
  new poll and eager task admission, includes every outstanding unused poll or
  eager reservation, and identifies each admitted task as either safely queued
  with its original attempt/deadline unspent or a tracked owner that finishes
  before the stop boundary. Before reopening after replacement, it SHALL prove
  every original PID/start-time instance has exited; fresh target metadata or
  unknown process visibility SHALL NOT substitute for that proof.
  The acknowledgement and resume operations SHALL be
  non-blocking with respect to SDK notification callbacks. A requested final
  transport handshake SHALL be bounded and SHALL NOT retain admission locks
  after durable completion. On timeout, unknown
  state, abort, replacement, or a worker that lacks the capability, the updater
  SHALL defer adoption before stop and leave admission recoverable; it SHALL
  NOT infer safety from an activity-body count, force-cancel an owner, change
  queues, retries, deadlines, concurrency, or budgets. Missing worker readiness
  metadata SHALL NOT be treated as evidence that no Temporal worker is running:
  the updater SHALL defer unless the supervisor state itself verifies that no
  Temporal worker will be stopped (the configured Unix control socket is absent
  and no same-workspace orphaned supervisor tmux session the stop path would
  kill hosts a Temporal worker window, a present socket positively refuses a
  local connection as stale and no such orphaned worker-bearing session exists,
  or a successful running-Overmind inspection reports
  no Temporal worker processes). An inspection counts as successful only when
  its output matches the supervisor's process-status grammar; a zero exit
  status with unparseable output SHALL be treated as a failed inspection, not
  as a report of no Temporal worker processes. Any other failed inspection
  SHALL be treated as unknown; when an orphaned session cannot be inspected,
  the updater SHALL not drain it but SHALL leave the stop path to fail before
  setup with the session identity rather than force-killing it. The
  capability SHALL cover both poll and agent roles and every enabled eager path
  (#5326).
  A separately authorized legacy idle-control cancellation SHALL verify the
  recorded first-execution identity through read-only metadata and target the
  exact recorded `run_id` without sending `first_execution_run_id`. It SHALL
  NOT follow a continued successor or treat RPC success as proof of the
  recorded run's cancellation. The updater SHALL NOT initiate this maintenance
  cancellation.
  *Current code:* `bin/dev-update` defers safely for ready legacy workers, for a
  running Overmind that still reports Temporal workers whose readiness metadata
  is missing, and for a socket-less or stale-socket same-workspace orphaned
  supervisor session whose tmux windows host a Temporal worker that the stop
  path would force-kill.
  *Protocol and rollout:*
  `decisions/task-safe-worker-quiescence.md`.
  *Required tests:* `spec/lib/paid/worker_admission_spec.rb`,
  `spec/lib/paid/worker_admission_controller_spec.rb`, `spec/lib/dev_update_spec.rb`.

## Durable Workflow Boundary

- [x] **TEMPORAL-ORCHESTRATION-003** — Durable multi-step automation SHALL run
  as Temporal workflows and activities under `app/temporal`, while lightweight
  recurring maintenance work remains in GoodJob.
  *Tests:* `spec/temporal/workflows/agent_execution_workflow_spec.rb`, `spec/config/good_job_configuration_spec.rb`.
  *Code:* `app/temporal/workflows/agent_execution_workflow.rb`, `config/initializers/good_job.rb`.

- [x] **TEMPORAL-ORCHESTRATION-005** — When the queue admits an agent
  execution workflow, the system SHALL mark the agent run `running` so
  provisioning/setup/preflight work appears as active execution rather than
  queued backlog.
  *Tests:* `spec/jobs/process_run_queue_job_spec.rb`,
  `spec/temporal/activities/run_agent_activity_spec.rb`.
  *Code:* `ProcessRunQueueJob`, `Activities::RunAgentActivity`,
  `AgentRun#start!`.

- [x] **TEMPORAL-ORCHESTRATION-006** — When a paused `create_feature` run has
  a persisted clarification-round identity, stale recovery SHALL leave it
  paused regardless of its age or the current issue `paid_state`. Paused
  executions without that run-owned clarification identity SHALL retain their
  existing bounded stale-recovery behavior.
  *Tests:* `spec/jobs/stale_run_detector_job_spec.rb`.
  *Code:* `AgentRun.awaiting_human_clarification`, `StaleRunDetectorJob`.

- [x] **TEMPORAL-ORCHESTRATION-008** — When stale recovery terminalizes a
  `create_feature` run with a persisted clarification-round identity and its
  issue retains both the needs-input label and stored questions, the system
  SHALL restore the issue to `needs_input` rather than leave the answer gate
  orphaned behind `failed`.
  *Tests:* `spec/jobs/stale_run_detector_job_spec.rb`.
  *Code:* `StaleRunDetectorJob`.

- [x] **TEMPORAL-ORCHESTRATION-007** — When a `create_feature` clarification
  comment is retried after GitHub accepted it but before local needs-input
  persistence completed, the system SHALL reconcile the persisted round
  identity against issue comments and SHALL not post a duplicate. Answering a
  round SHALL clear its identity so a later sparse brief can post a new round.
  *Tests:* `spec/temporal/activities/create_agent_run_activity_spec.rb`,
  `spec/services/clarifying_questions/clear_needs_input_spec.rb`.
  *Code:* `Activities::CreateAgentRunActivity`,
  `ClarifyingQuestions::ClearNeedsInput`.

- [x] **TEMPORAL-ORCHESTRATION-009** — When an issue has a pending
  clarification round (`needs_input` state, needs-input label, or stored
  questions), Paid SHALL reject a `create_pr` run before it can change the
  issue state. Other run goals SHALL leave that state unchanged. A queued
  `create_feature` run resumed after answers clear the pending data MAY
  transition the issue to `in_progress`. A positive
  `last_analyzer_sufficient_context` from a recent analyzer pass SHALL
  bypass the stale `needs_input_questions` check (the analyzer's verdict is
  authoritative when it has confirmed the question is answered) while
  preserving the rejection for an unresolved `paid_state: "needs_input"` or
  needs-input label (#4196).
  *Tests:* `spec/temporal/activities/create_agent_run_activity_spec.rb`
  ("rejects a create_pr run for an issue awaiting clarification without changing its state",
  "rejects a resumed create_pr run for an issue awaiting clarification without changing its state",
  "starts a create_pr run when the analyzer verdict confirmed sufficient context
  even though needs_input_questions is stored").
  *Code:* `Activities::CreateAgentRunActivity`,
  `ClarifyingQuestions::ClearNeedsInput`.

- [x] **TEMPORAL-ORCHESTRATION-010** — When the startup
  `CreateAgentRunActivity` call at the top of `AgentExecutionWorkflow#execute`
  raises (most commonly a non-retryable `IssueAwaitingInput` from
  `reject_create_pr_awaiting_input!`), the workflow SHALL mark the underlying
  `AgentRun` as failed with the actual rejection message before re-raising, so
  Temporal's terminal failure no longer leaves the row stuck at `running` while
  `StaleRunDetectorJob` repeatedly requeues it for the same blocked work
  (#4196). The startup booking runs from the same rescue block that handles
  later workflow failures; a successful startup unwinds into the regular
  `begin` / `rescue` block. Cancellations are re-raised unwrapped (no failed
  status write), and the workflow's existing cleanup path continues to run via
  `ensure`. The unwrap uses the same `unwrap_error_message` helper already in
  use for later failures so the recorded message is the actionable
  application error, not "Activity task failed".
  *Tests:* `spec/temporal/workflows/agent_execution_workflow_spec.rb`
  ("marks the run failed when startup CreateAgentRunActivity raises a non-retryable ApplicationError",
  "still runs the cleanup block when startup CreateAgentRunActivity fails",
  "does not write a failed status when startup CreateAgentRunActivity raises CanceledError",
  "uses the unwrapped ApplicationError message rather than 'Activity task failed'").
  *Code:* `Workflows::AgentExecutionWorkflow#execute`.

- [x] **TEMPORAL-ORCHESTRATION-012** — When queue admission encounters a
  uniqueness violation, it SHALL roll back its transaction or nested savepoint
  before looking up an existing active run. If an active run matches the work,
  admission SHALL match on either the issue or the source PR within the project
  and return it as a duplicate; otherwise it SHALL re-raise the
  original uniqueness error. Failed admission SHALL roll back enhancement-round
  accounting, SHALL leave the caller's transaction usable, and SHALL NOT enqueue
  queue processing.
  *Tests:* `spec/temporal/activities/queue_agent_run_activity_spec.rb`,
  `spec/temporal/activities/queue_agent_run_activity_concurrency_spec.rb`.
  *Code:* `Activities::QueueAgentRunActivity#execute`.

- [x] **TEMPORAL-ORCHESTRATION-014** — When a new agent workflow needs a
  proxy-health check before clone or push, it SHALL schedule the existing
  `CheckProxyHealth` activity on the existing poll queue without increasing
  worker capacity, changing tenant context, or changing its 30-second execution
  bound, 600-second recovery deadline or retry backoff. A Temporal patch SHALL
  preserve the original queue and timeout conversion when replaying unpatched
  histories. A schedule-to-start failure SHALL report unavailable worker
  execution rather than an observed endpoint outage; execution timeout and
  exhausted recovery SHALL remain distinct, and an observed unhealthy endpoint
  SHALL be identified only by its actual SDK-decoded failure cause. A zero
  final start-event ID alone SHALL NOT establish that earlier retries never
  executed; unobserved schedule-to-close exhaustion SHALL remain unknown
  recovery exhaustion. Configuration errors
  and cancellations SHALL not be converted into proxy-outage evidence. After
  successful agent execution, these control failures SHALL select the existing
  finite container-retention/recovery path; before successful execution they
  SHALL retain ordinary cleanup. Neither path SHALL skip health checks, push
  without authorization, report success or fabricate a result commit (#5240).
  *Tests:* `spec/temporal/workflows/agent_execution_workflow_proxy_health_spec.rb`,
  `spec/temporal/workflows/agent_execution_workflow_spec.rb`,
  `spec/temporal/workflow_replay_fixtures_spec.rb`,
  `spec/temporal/activities/check_proxy_health_activity_spec.rb`.
  *Code:* `Workflows::AgentExecutionWorkflow#ensure_proxy_healthy`.

- [x] **TEMPORAL-ORCHESTRATION-015** — When a new agent workflow must publish
  a quality-gate, startup or execution failure, it SHALL schedule the existing
  locked `MarkAgentRunFailed` activity on existing poll/control capacity with
  its unchanged 30-second execution and three-attempt retry bounds, and a
  120-second total scheduling/recovery bound. Unpatched histories SHALL retain
  their original routing, options and secondary-error behavior. New histories
  SHALL preserve the original execution failure if bounded bookkeeping fails,
  report the unavailable operation and retain normal cleanup/janitor handling.
  Cancellation SHALL not become a fabricated failure, late failure publication
  SHALL not overwrite a successful/cancelled terminal state, and long AI work,
  authority, retry allowances and resource capacity SHALL remain unchanged
  (#5248).
  *Tests:* `spec/temporal/workflows/agent_execution_workflow_terminal_control_spec.rb`,
  `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`,
  `spec/temporal/workflow_replay_fixtures_spec.rb`.
  *Code:* `Workflows::AgentExecutionWorkflow#execute`.

- [x] **TEMPORAL-ORCHESTRATION-016** — When a new report-only acceptance-audit
  workflow reaches terminal success, failure, or cancellation, Paid SHALL
  resolve cleanup ownership through a cancellation-detached activity on
  bounded poll/control capacity before scheduling cleanup, so an
  already-cancelled workflow token cannot skip owned-resource cleanup and the
  resolver is never queued behind a saturated agent pool. It SHALL skip
  container, MCP/tool-sidecar, service, worktree, and janitor commands only
  when their durable run references and execution-resource ledger show no
  owned resource. Persisted references and active ledger/worktree records,
  including resources from a resumed run, SHALL retain the matching existing
  cleanup, cancellation behavior, finite retention, and janitor path. A
  resolver failure SHALL retain legacy cleanup; it SHALL not move expensive
  cleanup to the poll queue, alter terminal failure publication, mint a retry,
  or alter closeout authority. The `cleanup-owned-resources-v1` Temporal patch
  SHALL preserve cleanup commands for unpatched histories (#5266).
  *Tests:* `spec/temporal/workflows/agent_execution_workflow_terminal_control_spec.rb`,
  `spec/temporal/workflows/agent_execution_workflow_cleanup_ownership_spec.rb`,
  `spec/temporal/workflows/base_workflow_spec.rb`,
  `spec/temporal/activities/resolve_cleanup_ownership_activity_spec.rb`,
  `spec/temporal/workflow_replay_fixtures_spec.rb`.
  *Code:* `Workflows::AgentExecutionWorkflow#resolve_cleanup_ownership`,
  `Activities::ResolveCleanupOwnershipActivity`, `AgentRuns::CleanupOwnership`.

- [x] **TEMPORAL-ORCHESTRATION-017** — When a post-push source-closure
  assessment needs to publish waiting recovery state, both the original agent
  workflow and the narrow recovery workflow SHALL schedule only the existing
  `ParkSourceClosureRecovery` activity through existing poll/control capacity,
  retaining its 30-second execution bound, existing retry semantics and a
  120-second total scheduling/recovery bound. The long assessment and agent
  activities SHALL retain their original queue, and a per-workflow Temporal
  patch SHALL preserve legacy commands and options for replay. Bounded
  publication failure SHALL remain an actionable failure without creating a
  PR, marking completion, bypassing assessment, changing authority/retry
  allowances, or overwriting a late terminal state. The detached short
  `EnqueueJanitor` scheduling operation SHALL use the same existing control
  capacity and a finite 120-second total bound for new histories, while
  expensive cleanup remains on its original route and a failed enqueue does
  not claim cleanup completed (#5268).
  *Tests:* `spec/temporal/workflows/agent_execution_workflow_spec.rb`,
  `spec/temporal/workflows/source_closure_recovery_workflow_spec.rb`,
  `spec/temporal/workflows/agent_execution_workflow_terminal_control_spec.rb`,
  `spec/temporal/workflow_replay_fixtures_spec.rb`.
  *Code:* `Workflows::AgentExecutionWorkflow#park_source_closure_recovery`,
  `Workflows::SourceClosureRecoveryWorkflow#park_source_closure_recovery`,
  `Workflows::AgentExecutionWorkflow#execute`.

- [x] **TEMPORAL-ORCHESTRATION-018** — When `AgentExecutionWorkflow`
  completes a run that pushed to an existing pull request, the
  `CompleteExistingPrRun` activity SHALL keep its existing agent queue, finite
  start-to-close deadline, and existing retry policy, and SHALL derive its
  internal assessment, comparison-read, update-summary, and publication
  budgets from the activity's actual
  remaining deadline rather than introducing independent fixed timeouts, with
  each bounded comparison read's elapsed time deducted from the shared
  deadline before its model request is admitted. The
  bounded poll/control queue SHALL continue to carry only established bounded
  control bookkeeping (failure publication, cleanup-ownership resolution,
  janitor scheduling); the completion activity's AI and GitHub work SHALL stay
  on the agent queue. When the activity raises the typed
  `ConflictRepairScopeRejected` review stop, the workflow SHALL publish that
  exact failure type on the run (normal PR/run/UI/API/MCP representations)
  through the existing failure-marking path, SHALL preserve the recorded
  result-commit SHA and workflow history, and SHALL retain the existing
  diagnostic container-retention and janitor ownership. A slow or unavailable
  PR publication SHALL NOT convert the stop into a generic timeout nor
  trigger rerun of coding/push work (#5310).
  *Tests:* `spec/temporal/workflows/agent_execution_workflow_spec.rb`,
  `spec/temporal/activities/complete_existing_pr_run_activity_spec.rb`.
  *Code:* `Workflows::AgentExecutionWorkflow#execute`,
  `Activities::CompleteExistingPrRunActivity`.

- [x] **TEMPORAL-ORCHESTRATION-019** — When `CreateAgentRunActivity` resumes
  an existing `AgentRun` that is `queued` or in the scheduler's pre-agent
  `running` state, Paid SHALL record secret-free,
  per-stage start, completion, and failure diagnostics for runner
  revalidation, feature assessment, issue-state publication, model selection,
  prompt preparation, user-settings/tier validation, marketplace attachment,
  policy evaluation, configuration-bundle assignment, and strategy selection.
  Each diagnostic SHALL identify only the run, tenant/project scope, Temporal
  attempt, stage, outcome, and elapsed time; it SHALL NOT include prompts,
  credentials, provider payloads, or exception messages. Before every resumed
  setup stage, Paid SHALL verify that the activity attempt still owns the
  queued-run resume attempt and that the run is not terminal. A superseded, cancelled, or
  late attempt SHALL stop before it can admit `RunAgent` work or overwrite a
  newer terminal outcome. Paid SHALL recheck this condition immediately before
  returning the resumed setup result, and `RunAgent` SHALL reject an already
  terminal run before it starts agent work. Retried setup SHALL retain the original run and
  workflow identity, tolerate already-persisted idempotent side effects, and
  remain bounded by the existing activity deadline and retry policy (#5356).
  *Tests:* `spec/temporal/activities/create_agent_run_activity_spec.rb`,
  `spec/temporal/activities/run_agent_activity_spec.rb`,
  `spec/temporal/workflows/agent_execution_workflow_spec.rb`.
  *Code:* `Activities::CreateAgentRunActivity#resume_queued_run`,
  `Activities::RunAgentActivity#execute`, `Workflows::AgentExecutionWorkflow#execute`.

- [D] **TEMPORAL-ORCHESTRATION-004** — When deployment requirements justify a
  hosted Temporal topology, the orchestration layer SHALL update this segment to
  describe the shipped operational model and its verification evidence.
