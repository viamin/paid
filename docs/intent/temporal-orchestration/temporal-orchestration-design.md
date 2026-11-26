---
parent: PAID
prefix: TEMPORAL-ORCHESTRATION
---

# Low-Level Design: Temporal Orchestration

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the implemented orchestration foundation described in
> `docs/rdrs/RDR-002-workflow-orchestration.md`.

## Purpose

Paid uses Temporal for durable, replay-safe orchestration of long-running agent
and automation workflows that must survive process restarts, cancellations, and
retries.

## Shipped Architecture

The shipped implementation uses the official `temporalio` Ruby SDK. Client
connections are created lazily from Rails so boot time does not eagerly load the
native Temporal client stack.

Workflow and activity code lives under `app/temporal/workflows` and
`app/temporal/activities`. This is the intentional shipped path layout,
replacing the earlier illustrative `app/workflows` and `app/activities`
examples in the RDR.

Temporal payloads use a Paid-owned `json/plain` converter. It calls JSON with
keyword options and does not enable object additions, matching the JSON 3 API
and preserving safe, deterministic serialization for clients, workers, and
checked-in workflow replay histories.

Evolution workflows are especially sensitive to this boundary because their
first durable command is an activity schedule. A worker or replayer using the
SDK default converter can decode the same `json/plain` history differently
from the Paid path and emit a different first command, which Temporal rejects
as non-deterministic. `Paid.temporal_worker_client` is therefore the only
worker client path, and replay verification supplies the same converter. The
codec contract is tested with both `PromptEvolutionWorkflow` and
`CoordinationPolicyEvolutionWorkflow`: their representative histories replay
with the Paid converter and fail with the SDK default converter. That test
establishes the compatibility condition, not the root cause of any opaque
historical failure. A recovery operator must inspect the pinned execution's
decoded history and loaded worker identity separately; `RUNNING` status and an
empty activity list are task-state observations, not liveness or a mandate to
discard work. Source delivery does not authorize cancellation, termination,
reset, replacement work, retry changes, budget changes, or completion of an
existing execution.

Paid runs separate Temporal task queues for polling and agent workloads. Poll
work is isolated from long-running agent execution so time-sensitive repository
polling does not compete with broader execution throughput.

The poll queue also carries the bounded `CheckProxyHealth` control activity.
Both worker modes already register that activity. Health checks retain their
30-second execution bound, 600-second recovery window and existing retry
backoff; they do not occupy a long-running agent activity slot while waiting
for the proxy. No activity-slot count or worker process is added. Other agent
activities retain their existing routing. The
`proxy-health-control-routing-v1` Temporal patch keeps recorded legacy health
commands on their original queue and failure behavior; new histories use the
control route (#5240).

A health activity that never obtained worker execution is a scheduling failure,
not evidence of a proxy outage. New histories distinguish schedule-to-start,
execution timeout, an exhausted recovery with an observed `ProxyUnhealthy`
cause, and exhausted recovery without that observation. A zero final attempt's
start-event ID does not prove that earlier retry attempts never executed;
schedule-to-close exhaustion without a supported endpoint observation remains
unknown recovery exhaustion. Messages contain only
bounded fixed categories and deadlines. Configuration errors and cancellations
retain their existing paths. These control failures leave a successful agent's
work eligible for the existing container-retention/recovery path and its finite
TTL; a failure before successful agent execution does not retain an otherwise
unused execution environment. A failed health check does not authorize push,
mark the run successful, replay coding work, or bypass the health gate.

Failure publication also needs short control capacity (#5248). New histories
route only `MarkAgentRunFailed` through the existing poll pool, retaining its
30-second execution bound and three-attempt retry policy, with a 120-second
total scheduling/recovery bound. The `failure-bookkeeping-control-v1` patch
preserves legacy routing and options. Long-running analysis and coding, normal
cleanup ownership and resource limits do not move into the control pool.

The activity retains its existing locked terminal-state guard: a late failure
cannot replace an already completed or cancelled run. Workflow cancellation
does not publish a fabricated failure. If bounded failure publication itself
fails, new histories preserve the original workflow failure, log the unavailable
bookkeeping operation and continue normal cleanup/janitor handling; they do not
invent a terminal database write, assessment or renewed retry allowance.

Report-only acceptance audits do not provision a coding container, MCP server,
service container, or worktree. New histories resolve cleanup ownership from
the persisted run and execution-resource ledger behind the
`cleanup-owned-resources-v1` Temporal patch before scheduling cleanup, through
the same detached-cancellation boundary the cleanup commands below it use
(`run_cleanup_activity`) and routed to bounded poll/control capacity. Both
properties matter: the detached boundary keeps the resolver schedulable when
the workflow token is already cancelled, so cancellation cannot skip
owned-resource cleanup; the poll/control routing keeps this cheap metadata
read off the agent queue, so a saturated agent pool cannot stall it either.
Empty ownership skips all cleanup and janitor commands; a persisted
container/runner handle or active ledger entry, MCP/tool-sidecar ID,
service-container ID, or active worktree retains the corresponding existing
cleanup and finite janitor path. The resolver's bounded failure fails safe to
the legacy cleanup set. Unpatched histories retain their recorded cleanup
commands. Only this metadata read moves to control capacity; expensive
cleanup commands and long-running AI work remain on the agent queue (#5266).

Post-push source-closure parking is also short control-plane state publication
(#5268). New `AgentExecutionWorkflow` and `SourceClosureRecoveryWorkflow`
histories route only `ParkSourceClosureRecovery` to the existing poll queue,
with its existing 30-second execution timeout, retry policy, run identity,
pushed commit, tenant context and 120-second total scheduling/recovery bound.
The `source-closure-recovery-control-routing-v1` patch is evaluated in each
workflow so recorded histories retain their original agent-queue command.
The long assessment and agent activities remain on their original queues. A
bounded publication failure remains an actionable workflow failure rather than
evidence that the state publication ran: it cannot synthesize a PR, completion,
assessment, authority or a new retry allowance, and existing locked terminal
guards preserve any pushed result.

The final `EnqueueJanitor` operation is similarly a short detached scheduling
operation, not resource cleanup. New `AgentExecutionWorkflow` histories route
only that activity to the existing poll queue with its unchanged 10-second
execution timeout, three attempts, and a 120-second total scheduling/recovery
bound through `enqueue-janitor-control-routing-v1`. A bounded enqueue failure
is logged while normal cleanup ownership and the expensive container, service,
MCP and worktree activities remain on their existing agent route; it does not
claim cleanup completed or abandon the live owner.

Existing-PR completion stays a single agent-queue activity with its existing
finite deadline and retry policy (#5310). The activity derives its internal
budgets from the Temporal start-to-close deadline it is actually running
under, rather than stacking independent fixed timeouts: the conflict-repair
scope assessment request receives only the deadline remaining after a
deliberate publication reserve, every comparison read (assessment evidence
and update-summary evidence alike) is bounded by the request budget it feeds
and deducted from the shared deadline before that request is admitted, and
rejection publication runs only inside
what remains after a final stop reserve. An activity retry reuses the
persisted assessment bound to the exact pre-run, integration-base, and pushed
head SHAs instead of issuing another harness request, so retries add no spend.
The assessment and its durable persistence precede any PR publication, and the
typed `ConflictRepairScopeRejected` review stop is raised even when PR-body
refresh or comment publication is slow, exhausted, or unavailable; the
workflow then publishes that exact failure type through the existing
failure-marking and diagnostic-retention paths. No workflow-history structure
changes, so in-flight runs replay unchanged, and no completion-path work
moves to the bounded poll/control queue.

Worker shutdown signals request cancellation and remove the readiness marker
from a normal Ruby thread. A watchdog starts before cancellation so a blocked
callback cannot prevent the forced exit. A repeated signal removes readiness
and forces exit. Signal traps avoid Ruby synchronization primitives, which
cannot run in trap context.

GoodJob still exists beside Temporal, but only for lightweight Rails job work.
Temporal owns the durable multi-step orchestration paths.

Agent execution rows move from `queued` to `running` when the queue admits the
Temporal workflow. Provisioning, setup, and preflight consume worker/container
capacity, so operators and capacity controls must see that work as active
rather than as ordinary waiting queue depth.

Queue admission uses a transaction and row locks, with unique indexes guarding
concurrent inserts. On a uniqueness violation, the admission transaction (or
its savepoint when nested) rolls back before querying for an existing active
run. Either the issue or the source PR can identify matching active work within
the project, including runs that reference different issue records for the same
PR. A matching active run is returned as a duplicate; otherwise the original
uniqueness error propagates for diagnosis. Failed admission rolls back any
enhancement-round accounting and does not enqueue queue processing.

## Human-input pauses and stale recovery

Stale recovery distinguishes a recoverable execution pause from a deliberate
`create_feature` clarification wait. A paused `create_feature` run carrying a
persisted clarification-round identity is owned by the human-answer flow, not
the stale-run detector: it remains paused regardless of age until that flow or
another explicit supported action requeues it. This run-owned identity remains
authoritative if another write temporarily drifts the issue's `paid_state`.
Other paused runs retain the bounded stale-recovery policy. If another stale
recovery path terminalizes a run carrying that identity while its needs-input
label and stored questions still exist, it restores the issue to `needs_input`
rather than orphaning the answer flow behind `failed`.

Each clarification round has a run-persisted identity embedded in its GitHub
comment. The identity is saved before posting. A retry or restarted workflow
first reconciles issue comments with that identity, then persists the local
needs-input state without reposting if GitHub already accepted the comment.
Answering clears the identity, allowing a later genuinely new round to post.
Run-start processing preserves that human-owned pause: a pending clarification
round blocks `create_pr` before it can overwrite the issue's state. Other run
goals may start, but leave that clarification-owned state unchanged. The
resumed `create_feature` run proceeds only after answer handling clears the
pending label and stored questions.

A successful `analyze_issue` pass that returns `sufficient_context: true`
also reconciles a stale `needs_input_questions` payload on the issue: the
analyzer's verdict is authoritative, and an old question that the human has
already answered should not block the follow-up `create_pr` queue. The
reconciliation in `AnalyzeIssueActivity#complete_run!` clears the stored
questions and the local needs-input label only when the verdict is positive,
so a genuinely unanswered `needs_input` round still trips
`CreateAgentRunActivity#clarification_pending?` and is rejected at queue
time (#4196).

The workflow's startup `CreateAgentRunActivity` call runs through the same
rescue path as later failures: a non-retryable application error (most
commonly `IssueAwaitingInput`) now writes a `failed` terminal status with
the actual rejection message before re-raising, so Temporal's terminal
failure no longer leaves the row stuck at `running` while
`StaleRunDetectorJob` repeatedly requeues the same blocked work. Cancellations
are re-raised unwrapped (no failed status write), and the existing cleanup
path continues to run via `ensure` (#4196).

## Queued-run resume diagnostics

Queued runs are resumed inside the existing `CreateAgentRun` activity before
any coding, container, or provider-runner activity is scheduled. The activity
keeps its existing 30-second start-to-close deadline and native retry policy.
It records a compact progress event before and after each local setup stage so
the last recorded start identifies an unfinished or timed-out dependency.
Events contain only stable IDs, Temporal attempt number, stage name, outcome,
and elapsed milliseconds; prompts, credentials, provider payloads, and
exception text are excluded.

Each stage rechecks the run's persisted resume-attempt ownership and terminal
state. The scheduler's pre-agent `running` state remains eligible alongside
`queued`, because queue admission marks the row active before this activity
performs setup. After Temporal accepts the workflow, provisioning bookkeeping
locks and reloads the run before merging metadata, preserving resume ownership
or terminal evidence written by an activity that has already started.
A later Temporal attempt supersedes an earlier one, and a
terminal run supersedes both. A superseded attempt raises a typed non-retryable
setup error instead of returning a successful activity result, so it cannot
advance the workflow to `RunAgent` or overwrite the newer terminal result. The
activity repeats that check immediately before returning its admission payload,
and `RunAgent` separately rejects an already-terminal run before starting
agent work.
Setup remains idempotent on retry: runner synchronization, marketplace
attachment, model selection, policy persistence, configuration assignment, and
strategy logging reuse their existing persisted records. This is an
observability and late-attempt fencing change; it neither moves work to a control pool nor
widens execution, retry, model, or authority budgets (#5356).

## Worker Capacity Model

Temporal worker configuration derives the minimum Active Record pool size from
the selected worker mode and activity-slot counts. Regular activities can
consume an additional database connection through heartbeat helper threads, so
pool sizing must account for both activity slots and heartbeat threads.

## Task-Safe Worker Quiescence

The selected protocol closes future reservations before waiting for exclusive
ownership of every already-issued workflow and remote activity permit. It uses
the installed SDK's public custom-slot callbacks; no hypothetical lifecycle
method or private bridge operation is required. The request is not an
acknowledgement. Only exclusive ownership of the complete affected role set,
with unchanged trusted boot identities, authorizes a stop.

Permits retain shared ownership from reservation through SDK release. New
blocking reservations wait cancellably after a request, while eager reservation
attempts return immediately. Notification callbacks never acquire an admission
fence after assignment and never publish readiness files. Existing fixed slot
counts, queues, task deadlines, retries and shutdown grace are preserved.

The capability covers Paid's registered workflows and remote activity boundary.
The unused fixed local-activity supplier remains unchanged. General local
activity, Nexus or additional worker configurations must not advertise this
capability without their own proven ownership protocol. Both poll and agent
roles, including sticky workflow polling and enabled remote eager admission,
require real SDK/server verification before TEMPORAL-ORCHESTRATION-021 can be
marked implemented.

The standalone updater uses a controller outside restarted services, with
serialized generation ownership, persistent fail-closed requests and
non-inherited lock descriptors. Timeout before acknowledgement aborts only the
caller's request without stopping workers; an interrupted acknowledged update
has an explicit recoverable generation, never a false success. The Bash caller
uses non-inherited control pipes. An optional bounded completion handshake keeps
the controller available until the caller reads the durable final outcome;
losing that caller never retains admission locks after completion. Unsupported
legacy workers and missing or ambiguous readiness defer before stop. A
controlled empty-workload maintenance bootstrap is separate from steady-state
adoption. The complete protocol, legacy preconditions and real verification
matrix are in [the quiescence decision](decisions/task-safe-worker-quiescence.md).

## Health control routing alternatives

| Choice | Decision | Alternatives | Rationale |
| --- | --- | --- | --- |
| Existing poll worker for the bounded health activity | Selected | New worker process or larger agent slot count | Its activity registration and capacity already exist independently of long agent work. |
| Longer health deadline on the agent queue | Rejected | Existing poll worker | A queued check still supplies no endpoint observation and can discard completed work. |
| Task-safe worker quiescence | Two-stage request and reservation-to-release ownership through public SDK suppliers, subject to real verification | Activity-body locks; permit transfer after assignment; reader renewal without a request; shutdown as a reversible fence | Closing renewal lets outstanding poll and eager permits settle before exclusive acknowledgement. Unproven or legacy roles defer, and unknown supervisor state never proves absence. |

## Deferred Work

Operational choices such as deployment topology changes or Temporal Cloud
adoption are outside this brownfield backfill. This segment documents the
currently shipped self-managed Ruby worker model.
