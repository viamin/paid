# EARS Specs: Agent Run Retry Contract

> Testable claims for the shared retry contract and migration map across
> Paid's agent-run and agent-run-style attempt retry (and deliberate
> no-retry) paths (#4986). Status markers: `[x]` implemented ·
> `[ ]` active gap · `[D]` deferred. Each ID is a grep target across specs,
> tests, and code (`grep -r AGENT-RETRY-001`).
>
> This segment governs no runtime files. `[x]` specs below describe
> already-shipped behavior in the paths named by the policy matrix, cited
> here to make the shared contract's invariants grep-able from one place;
> they are not claims about new code added by this segment.

## Scope and non-goals

- [x] **AGENT-RETRY-001** — The system SHALL treat Temporal's per-activity
  retry policy (e.g. `AgentExecutionWorkflow::RUN_AGENT_RETRY_POLICY`) as an
  infrastructure-level re-invocation inside one logical attempt, not as an
  attempt boundary this contract governs — application errors raised
  inside an activity SHALL remain `non_retryable` there, and this
  contract's scope SHALL begin only once that policy's retries are
  exhausted and `MarkAgentRunFailedActivity` runs.
  *Code:* `app/temporal/workflows/agent_execution_workflow.rb`.

- [x] **AGENT-RETRY-002** — The system SHALL NOT provide a universal
  "replay this `AgentRun`" operation; each retry-shaped path SHALL retain
  its own eligibility predicate, input snapshot, side-effect check, and
  dispatch rule rather than delegate them to a shared replay method.
  *Code:* absence verified by inspection — no `AgentRun#replay!` or
  equivalent universal replay method exists as of this spec.

## Identity and attempt lineage

- [x] **AGENT-RETRY-003** — Where an existing identity record already
  captures attempt lineage for a retry-shaped path, the system SHALL reuse
  it rather than introduce new persisted state for that path.
  *Code:* `AgentRun::MANUAL_RETRY_ATTEMPT_METADATA_KEY`,
  `AppleVerificationAttempt#retry_of_attempt_id`
  (`db/migrate/20260921005044_add_retry_of_attempt_to_apple_verification_attempts.rb`),
  `Issue#consecutive_auto_pick_failure_count`,
  `AgentRun#stale_requeue_count`.

## Durable decision reasons

- [x] **AGENT-RETRY-004** — When a retry-shaped path claims, defers, or
  refuses another attempt, it SHALL record a durable decision reason
  (`OrchestrationDecision`, or an equivalent durable audit event for a
  path that uses its own evidence record) including enough signals and
  result data to reconstruct why, so an operator can trace a superseded
  attempt to its replacement (or to its terminal refusal) after the fact.
  *Code:* `app/models/orchestration_decision.rb`,
  `AgentRun#retry!` / `AgentRun#log_orchestration_decision`.

## Cross-cutting safety requirements

- [x] **AGENT-RETRY-005** — Duplicate jobs: the system SHALL re-check
  attempt eligibility under a row lock immediately before claiming another
  attempt, not only at schedule time, so a duplicated or re-delivered
  delayed job cannot double-claim the same logical operation.
  *Code:* `RetryFailedManualRunJob#perform`,
  `RetryTimedOutIssueGoalJob#perform`,
  `StaleRunDetectorJob#recover_rate_limited_run`.

- [x] **AGENT-RETRY-006** — Concurrent schedulers: the claim SHALL be a
  single atomic transaction keyed off a unique index or row lock, and a
  losing concurrent claim SHALL recognize its specific conflict and
  resolve to a no-op rather than an unhandled error.
  *Code:* `idx_agent_runs_unique_active_lid_planning` handling in
  `RetryFailedManualRunJob`, `idx_agent_runs_unique_active_issue` /
  `idx_agent_runs_unique_active_pr` handling in
  `RetryTimedOutIssueGoalJob`'s `RecordNotUnique` rescue,
  `idx_apple_attempts_one_active_per_run`.

- [x] **AGENT-RETRY-007** — State changes during backoff: eligibility
  SHALL be re-evaluated against current state at claim time, never trusted
  from schedule time, so a toggle flipped, a sibling run claiming the
  identity's slot, or the run already being retried during the backoff
  window is visible to the claim.
  *Code:* same locked re-checks as AGENT-RETRY-005.

- [x] **AGENT-RETRY-008** — Partial external work: an attempt that already
  produced an observable side effect SHALL NOT be blindly retried; the
  side-effect check SHALL be a precondition independent of terminal
  status, never inferred from status alone.
  *Code:* `AgentRun#no_observable_work?`,
  `idx_apple_attempts_one_active_per_run` plus
  `AppleVerificationAttempt#retry_of_attempt_id` binding a retry to one
  specific terminal source rather than "the latest failure."

- [x] **AGENT-RETRY-009** — Exhausted budgets: every retry-shaped path
  SHALL enforce a bounded, per-logical-operation attempt counter with a
  terminal, durably visible stop; none SHALL retry unboundedly.
  *Code:* `AgentRun::MAX_MANUAL_RETRY_ATTEMPTS`,
  `RetryTimedOutIssueGoalJob::MAX_RETRIES`,
  `AgentRun::MAX_RATE_LIMITED_REQUEUES`, Apple verification's retry limit
  and queue-depth cap, acceptance audit's one-attempt-per-digest cap.

- [x] **AGENT-RETRY-010** — Restart recovery: recovery SHALL re-derive
  state from durable rows rather than in-memory job state, so a process
  restart between claim and dispatch resolves unambiguously to "not yet
  attempted" or "already attempted."
  *Code:* `AgentRun` status column plus `OrchestrationDecision`,
  `AppleVerificationAttempt` status plus external-resource-ledger
  reconciliation (APPLE-WORKER-010).

## Explicit operator-triggered policies preserved

- [x] **AGENT-RETRY-011** — The contract SHALL preserve `bootstrap_readiness`
  as a non-retry, operator-triggered-only policy. No adoption of the
  shared interface shape by any path SHALL silently expand
  `bootstrap_readiness` (or any other explicitly operator-gated goal) to
  automatic retry.
  *Code:* `AgentRun#bootstrap_readiness_goal?` exclusion inside
  `Activities::MarkAgentRunFailedActivity#manual_run_retry_eligible?`
  (PROJECT-READINESS-007).

## Migration map and first slice

- [x] **AGENT-RETRY-012** — The policy matrix SHALL name, for every
  retry-shaped path in scope (manual issue-less runs, timed-out
  `create_issue`, auto-picked `create_pr`/`analyze_issue`, in-place
  rate-limit recovery, Temporal activity recovery, acceptance audits, and
  Apple verification attempts), its owner, identity, existing retry
  behavior, stop conditions, and migration slice.
  *Doc:* this segment's design, "Policy matrix" section.

- [x] **AGENT-RETRY-013** — The first implementation slice of the shared
  contract SHALL be the existing issue-less manual-run retry path,
  adopted as the reference implementation with no runtime behavior change.
  *Code:* `app/temporal/activities/mark_agent_run_failed_activity.rb`,
  `app/jobs/retry_failed_manual_run_job.rb` (both unchanged by this
  segment — adoption is a documentation cross-reference only).

- [ ] **AGENT-RETRY-014** — Where a later acceptance-audit adapter is
  built (tracked as separate, in-progress work), it SHALL keep
  `(issue_id, closeout_evidence_digest)` as the logical identity and add an
  attempt-lineage dimension beneath it so more than one execution attempt
  can occur under one evidence digest, and it SHALL classify an audit
  failure as infrastructure or deterministic before counting it against
  any attempt budget.
  *Deferred to the separate audit-recovery work; no acceptance-audit
  runtime file is changed by this segment.*
