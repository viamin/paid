---
parent: PAID
prefix: AGENT-RETRY
---

# Low-Level Design: Agent Run Retry Contract

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment names the shared vocabulary and minimal interface shape for
> "another attempt at the same logical operation" across Paid's existing
> retry (and deliberate no-retry) paths for agent runs and agent-run-style
> attempts (#4986). It is a map and a contract with reusable claim mechanics:
> every path keeps its own owner, identity, and dispatch logic.

## Purpose

Paid has grown seven independent places that decide whether a failed
execution gets another try, each with its own identity, budget, and
admission rules: issue-less manual runs, timed-out `create_issue` runs,
auto-picked `create_pr`/`analyze_issue` runs, in-place rate-limit recovery,
Temporal's own activity-level retry, acceptance audits, and Apple
verification attempts. They converged independently on the same shape —
bounded attempt count, row-lock re-check at claim time, a durable decision
record — without a shared name for any of it. A future path (most urgently,
letting acceptance audits retry under one evidence digest) would otherwise
reinvent that shape again or, worse, borrow one path's dispatch rule where
it does not fit.

This segment:

- Names the vocabulary (logical operation, attempt, fresh assessment)
  precisely enough to classify every path in the matrix below.
- Documents the minimal interface shape a use-case-owned retry policy can
  implement, without creating a universal "replay this row" operation.
- Maps every path to its owner, identity, current behavior, stop
  conditions, and migration slice.
- States the cross-cutting safety properties any adopter of the shared
  shape must satisfy, each grounded in an existing exemplar.
- Declares the first migration slice (issue-less manual-run retry,
  already shipped under `docs/intent/manual-run-retry/`) and explicitly
  excludes acceptance-audit runtime files from this change.

## Scope and non-goals

In scope: the application-level decision "has this logical operation's
work failed in a way that deserves another execution attempt, and if so,
who may claim it." This governs `AgentRun`-identified work and
`AppleVerificationAttempt`-identified work, which share the same shape
(terminal row → bounded budget → claim under lock → linked successor).

Out of scope:

- **A universal "replay AgentRun" operation.** `create_pr`'s identity is
  the issue; rate-limit recovery's identity is the row itself; acceptance
  audit's identity is `(issue, evidence_digest)`. A single replay method
  over `AgentRun` would have to average over these, which is exactly the
  failure mode EAGER-QUEUE-007 and the rate-limit path independently
  avoided by owning their own admission rules. Each use case keeps its own
  eligibility check, input snapshot, side-effect check, and dispatch rule;
  this segment only names the shared shape across them.
- **Temporal's own activity-level retry policy** (e.g.
  `AgentExecutionWorkflow::RUN_AGENT_RETRY_POLICY`, `max_attempts: 2`).
  That mechanism re-invokes the *same* activity call inside *one* logical
  attempt when the worker crashes or a heartbeat times out; application
  errors are marked `non_retryable` so it never retries a deterministic
  failure. It operates strictly below the attempt boundary this contract
  defines — this contract's scope begins where that policy's retries are
  exhausted and `MarkAgentRunFailedActivity` runs. See
  `docs/intent/temporal-orchestration/`.
- **Changing any path's current runtime behavior.** Nothing in this
  segment alters an existing eligibility check, budget, or dispatch rule.
  The policy matrix below records current behavior as read from the code
  today; it is a description, not a migration.
- **Acceptance-audit runtime files.** The separate audit-recovery work in
  progress owns that change. This segment only names where a future
  adapter would plug in (see "Acceptance-audit adapter" below) and touches
  no file under the audit runtime.

## Core vocabulary

- **Logical operation** — the stable thing a retry is "another attempt
  at." Examples: "open a PR for issue #123," "run this manually-submitted
  `create_feature` request," "verify commit `abc123` against workflow
  revision 4." Its identity must survive across attempts without being
  recomputed from attempt-local state.
- **Attempt** — one execution try at a logical operation. An attempt may
  be a brand-new persisted row (a new `AgentRun`, a new
  `AppleVerificationAttempt`) or an in-place re-queue of the same row
  (rate-limit recovery). Both are attempts; which shape a given path uses
  is a dispatch-rule decision owned by that path, not by this contract.
- **Fresh assessment** — a new logical operation triggered by changed
  inputs (a new closeout-evidence digest, a new commit, a new issue-intent
  revision). A fresh assessment is never counted against a prior logical
  operation's attempt budget — this is why a new merged PR earns acceptance
  audit exactly one new attempt rather than being blocked by the old
  digest's exhausted budget.

## Shared interface shape (conceptual)

Each use case already implements, in its own words, the same three
decisions. Naming them gives future adopters (and reviewers) a shared
vocabulary without forcing a shared base class:

```ruby
# `RetryableAttempts::RetryAttempt` ships this mechanics shape. A use-case-owned
# policy supplies admission and successor construction.
module Retryable
  module AttemptPolicy
    # The stable identity of the logical operation this terminal row or
    # event belongs to. Must be derivable without side effects (e.g. project
    # + issue_id, or project + goal + custom_prompt shape, or
    # issue_id + closeout_evidence_digest).
    def logical_identity(terminal_row); end

    # True when another attempt is admissible right now: budget not
    # exhausted, failure class retryable, no partial side effect blocks a
    # blind retry, and any use-case-owned admission recheck (toggle, active
    # sibling, state drift since the failure) passes.
    def eligible_for_attempt?(terminal_row); end

    # Atomically marks the terminal row superseded and creates or schedules
    # the next attempt, inside the one transaction/row lock that also
    # re-validates eligibility. Returns the new attempt or a durable no-op
    # reason (never raises for an expected conflict).
    def claim_next_attempt!(terminal_row); end
  end
end
```

A use case implementing this shape keeps everything else to itself: its
own eligibility predicate, its own input snapshot (what exactly gets
re-run), its own side-effect check, and its own dispatch rule (mint a new
row, re-queue in place, or re-seed a parent record like an `Issue`). The
contract is the three questions above, not a shared implementation of the
answers.

## Policy matrix

| Path | Owner | Identity | Existing retry behavior | Stop conditions | Migration slice |
| --- | --- | --- | --- | --- | --- |
| Manual issue-less runs (`create_feature`, `create_issue`, `lid_planning`, issue-less `create_pr`) | `Activities::MarkAgentRunFailedActivity#schedule_manual_run_retry_if_eligible` + `RetryFailedManualRunJob` (`docs/intent/manual-run-retry/`) | `(project, goal, runner, agent_type, custom_prompt, plan_doc_source)` shape carried forward on a fresh row; lineage via `external_metadata["manual_retry_attempt"]` / `"retried_from_agent_run_id"` | Mints a new `AgentRun`, marks the original `"retried"`, bounded exponential backoff (30s/1m/2m, capped 5m), budget 3 (`AgentRun::MAX_MANUAL_RETRY_ATTEMPTS`), gated by `Project#retry_failed_manual_runs`, only when `AgentRun#no_observable_work?` | Budget exhausted; any observable work produced; `recoverable_rate_limited?`; `bootstrap_readiness` goal; project toggle off | **First slice** (adopted as-is, see below). |
| Timed-out `create_issue` | `RetryTimedOutIssueGoalJob` + `AgentRuns::TimeoutIssueGoalRetryPolicy` | `(project, issue_id)` when issue-attached; otherwise a generated `create_issue_operation_key` carried through the retry chain, with legacy parameter matching used only to establish the first keyed replacement | The shared mechanism locks and reassesses the timed-out source, then mints a new manual-priority `AgentRun` or dispatches the already-active sibling found before admission or after a unique-index race. The policy preserves copied inputs, a three-replacement budget, operation-key attempt lineage, and `OrchestrationDecision` evidence | Budget reached; an existing active run already claims the issue or PR unique slot; source no longer a timeout `create_issue` run | **Adopted** — timeout identity, active-sibling handling, and decision recording remain policy-owned while the generalized service owns the locked claim. |
| Auto-picked `create_pr` (issue-driven) | `Issue#enqueue_self_if_became_auto_pick_eligible` + `AgentRuns::AutoPickCreatePrRetryPolicy` + `RetryFailedAutoPickCreatePrJob` (`docs/intent/eager-queue-seeding/`, EAGER-QUEUE-007/EAGER-QUEUE-018) | `issue_id` — the *issue* carries retry budget and backoff state; the failed `AgentRun` is the locked decision source | The issue schedules its existing `(n**4)+15+jitter` delay; the shared mechanism re-checks and claims the failed source under lock, then delegates normal `Issues::EnqueueEligible` admission to mint a successor. The original run is marked `retried` with an `OrchestrationDecision` linked to that successor. Since the #4989 acceptance bypass fix, ordinary admission (`Issues::EnqueueEligible`, via `Issue#auto_pick_create_pr_admission_hold`) refuses a fresh implementation attempt for the same produced-work / in-place-rate-limit refusals the policy records, scoped to the authorized reset window, so sweeps and delayed re-enqueues cannot route around a refused shared decision. A retryable partial-closeout reconciliation with recorded assessment gaps returns to normal eligibility instead; that path independently verifies the assessment is current before admitting a continuation. | Issue no longer eligible; retry-limited Inbox parks the issue; `auto_pick_enabled` off; recoverable in-place rate limit; any PR, pushed revision, or observable implementation work | **Second slice** — the adapter reuses shared decision/claim mechanics without changing issue-owned scheduling or admission. |
| Auto-picked `analyze_issue` (issue-driven) | `Issue#enqueue_self_if_became_auto_pick_eligible` → `Issues::ReenqueueEligibleJob` (`docs/intent/eager-queue-seeding/`, EAGER-QUEUE-007) | `issue_id` — the *issue* carries the retry-chain state (`consecutive_auto_pick_failure_count`), not a terminal row | No attempt row is minted ahead of time: the issue re-enters the eligibility queue and `Issues::EnqueueEligible` mints the `AgentRun` only when a scheduler actually claims it. Backoff `(n**4)+15+jitter` (no numeric cap); effectively bounded by parking the issue in the retry-limited Inbox once the effective retry cap is reached | Issue no longer eligible; retry-limited Inbox parks the issue; `auto_pick_enabled` off | Later — retained outside this slice. |
| In-place rate-limit recovery | `StaleRunDetectorJob#recover_rate_limited_run` | The same `AgentRun` row (`status: "rate_limited"`, `rate_limited_until` elapsed) | No new row — in-place re-queue under row lock, budget via `stale_requeue_count` against `AgentRun::MAX_RATE_LIMITED_REQUEUES`, admission recheck via `active_sibling_exists?`, capacity-parked attempts exempt from budget decrement | Budget exhausted → terminal `failed`; active sibling already owns the identity's unique slot → terminal `failed`, superseded | Later — already in-place-attempt-shaped; a natural second reference for the in-place half of the contract (as opposed to manual-run-retry's mint-new-row half), tracked separately. |
| Temporal activity recovery | Temporal server + `AgentExecutionWorkflow`'s per-activity `RetryPolicy` (e.g. `RUN_AGENT_RETRY_POLICY`, `max_attempts: 2`) | The in-flight workflow execution / activity task — not an `AgentRun` | Infra-only re-invocation of the *same* activity call inside one logical attempt (worker crash, heartbeat timeout); application errors are marked `non_retryable` in the activity itself | `max_attempts` exhausted → activity failure propagates to `MarkAgentRunFailedActivity`, which is where this contract's scope begins | **Not migrated — different layer**, named here only so it is not mistaken for an unmapped gap (see Scope and non-goals). |
| Acceptance audits | `MarkAgentRunFailedActivity#schedule_acceptance_audit_retry_if_eligible` + `AcceptanceAuditRetryJob` claiming via `PartialCloseouts::RetryAcceptanceAudit` (`docs/intent/partial-closeout-recovery/`, #4992; PARTIAL-CLOSEOUT-056) | `(issue_id, closeout_evidence_digest)` on the acceptance-audit continuation request; attempt lineage beneath it via `external_metadata["acceptance_audit_retry_attempt"]` / `"acceptance_audit_retry_of_agent_run_id"` | Mints a fresh continuation request and run through the ordinary `Issues::RequestAcceptanceAudit` admission path (every auto-pick/trust/pause/dependency/budget/one-open-request guard rechecked), marks the failed attempt `"retried"`, bounded backoff 30m/60m, budget 3 per source revision (`PartialCloseouts::AutoAudit::MAX_ATTEMPTS`); only `PartialCloseouts::AcceptanceAuditFailure`-classified transient transport/infrastructure failures are eligible — a substantive assessment (including unmet criteria), cancellation, auth/config failure, budget exhaustion, rate-limit recovery, non-transient failure, or changed evidence is never retried | Budget exhausted (visible with reason via `AutoAudit.retry_state`); classification non-transient; evidence digest changed; another authorization open; backoff not elapsed; ordinary admission refuses | **Migrated (#4992)** — the acceptance-audit adapter this segment documented as its extension point; claim serialized on the issue row lock because that is where the path's identity lives. |
| Apple verification attempts | `AppleVerificationAttempts::RetryMonitor` + `AppleVerificationRetryJob` (`docs/intent/apple-verification-attempts/`, APPLE-ATTEMPT-010) and the rerun flow (APPLE-VERIFY-006) | `retry_of_attempt_id` lineage to the terminal source attempt, scoped by `agent_run_id` | An idempotent queued retry bound to its terminal source attempt; retries only infra-classified failures (`capacity_or_quota`, `worker_infrastructure`, `cancellation_or_timeout`), bounded by a configurable retry limit and queue depth; `idx_apple_attempts_one_active_per_run` enforces one active attempt per run | Non-infra failure classification (deterministic project failure); retry limit reached; queue depth cap | **Second slice** — `RetryableAttempts::RetryAttempt` locks and re-assesses the terminal attempt before `AppleVerificationAttempts::RetryPolicy` admits and creates its linked successor. |
| `bootstrap_readiness` (explicit operator policy) | `AgentRun#bootstrap_readiness_goal?` exclusion inside `AgentRuns::ManualRunRetryPolicy#assess`; PROJECT-READINESS-007 | `(project, bootstrap_readiness goal)` | **No automatic retry of any kind.** A failed bootstrap run stays terminal until an operator explicitly starts a replacement from the project-setup Inbox entry | N/A — only an explicit operator action unblocks it | **Must not be migrated.** No adoption of the shared shape may silently add automatic retry to this path; its absence of retry is the policy, not a gap. |

## Cross-cutting safety requirements

Any path that adopts the shared interface shape — and every path in the
matrix above already satisfies these, which is how the matrix was built —
must hold the following, each grounded in an existing exemplar:

- **Duplicate jobs.** Re-check attempt eligibility under a row lock
  immediately before claiming, not only at schedule time, so a duplicated
  or re-delivered delayed job cannot double-claim. (`RetryableAttempts::RetryAttempt#claim`'s
  attempt-class `lock.find_by` re-check for manual, timeout, and Apple attempts;
  `StaleRunDetectorJob#recover_rate_limited_run`'s
  `with_lock`.)
- **Concurrent schedulers.** The claim is a single atomic transaction keyed
  off a unique index or row lock, and a losing concurrent claim recognizes
  its specific conflict and resolves to a no-op rather than an unhandled
  error. (`idx_agent_runs_unique_active_lid_planning` handling in
  `RetryableAttempts::RetryAttempt#claim` via
  `AgentRuns::ManualRunRetryPolicy#duplicate_active_run_conflict?`;
  `idx_agent_runs_unique_active_issue`/`_pr` handling in
  `AgentRuns::TimeoutIssueGoalRetryPolicy#handle_duplicate_claim!`;
  `idx_apple_attempts_one_active_per_run`.)
- **State changes during backoff.** Eligibility is re-evaluated against
  current state at claim time, never trusted from schedule time — a
  toggle flipped, another run claiming the slot, or the run already being
  retried must all be visible to the claim, not just the schedule.
  (For manual runs, `RetryableAttempts::RetryAttempt#claim` performs the locked
  re-check above.)
- **Partial external work.** An attempt that already produced an
  observable side effect must not be blindly retried; the side-effect
  check is a hard precondition independent of terminal status, never
  inferred from status alone. (`AgentRun#no_observable_work?`; Apple
  verification's one-active-attempt-per-run index plus
  `retry_of_attempt_id` lineage so a retry is explicitly bound to one
  terminal source, never to "the latest failure.")
- **Exhausted budgets.** Every path enforces a bounded, per-logical-operation
  attempt counter with a terminal, durably visible stop; none retries
  unboundedly. (`MAX_MANUAL_RETRY_ATTEMPTS`, `RetryTimedOutIssueGoalJob::MAX_RETRIES`,
  `AgentRun::MAX_RATE_LIMIT_REQUEUES`, Apple verification's retry limit
  and queue-depth cap, acceptance audit's three-attempts-per-digest cap.)
- **Restart recovery.** Recovery re-derives state from durable rows, not
  in-memory job state, so a process restart between claim and dispatch
  resolves unambiguously to "not yet attempted" or "already attempted."
  (`AgentRun` status plus `OrchestrationDecision`; `AppleVerificationAttempt`
  status plus external-resource-ledger reconciliation, APPLE-WORKER-010.)

## Identity, attempt lineage, and durable decision reasons

No path in the matrix needs new persisted state to express attempt
lineage — each already has a column or record that does the job:

- `AgentRun#external_metadata["manual_retry_attempt"]` /
  `"retried_from_agent_run_id"` (manual-run-retry).
- `AgentRun#external_metadata["create_issue_operation_key"]` and
  `["create_issue_retry_attempt"]` for timed-out `create_issue`
  replacements. A terminal legacy row without those values uses the former
  identity/parameter count only to establish its first keyed replacement.
- `Issue#consecutive_auto_pick_failure_count` (EAGER-QUEUE-007), with the
  failed `create_pr` `AgentRun` as the locked source for the shared claim.
- `AgentRun#stale_requeue_count` (in-place rate-limit recovery).
- `AppleVerificationAttempt#retry_of_attempt_id` (Apple verification). This
  remains Apple verification's only retry ledger: the shared claim result
  exposes a refusal reason but does not create an `AgentRun` or a second
  `OrchestrationDecision` identity for the attempt.
- The `(issue_id, closeout_evidence_digest)` pair recorded on the acceptance
  audit's continuation request, with execution-attempt lineage beneath it via
  `AgentRun#external_metadata["acceptance_audit_retry_attempt"]` /
  `"acceptance_audit_retry_of_agent_run_id"` (partial-closeout-recovery,
  #4992).

Durable decision reasons reuse `OrchestrationDecision` (`project`, `issue`,
`agent_run`, `decision_point`, `action`, `status`, `signals`, `result`),
already the mechanism `AgentRun#retry!` →
`AgentRun#log_orchestration_decision` writes to for both manual-run-retry
and the timed-out-issue-goal path. Since #4992 the acceptance-audit retry
claim and its refusals also record `OrchestrationDecision` rows (decision
point `acceptance_audit_auto_retry`) because they are execution-retry
decisions; the path's evidence-sufficiency decisions remain audit events on
the partial-closeout reconciliation record, and the two record types stay
distinct.

## Cancellation and side-effect safety

A superseded attempt's terminal marking and the next attempt's creation
happen inside the same lock, never as two separate writes: `AgentRun#retry!`
updates `status: "retried"` and writes the `OrchestrationDecision` in one
`with_lock` block, and every mint-new-row path in the matrix marks the
original superseded before (or atomically with) creating the replacement.
This prevents a window where both the old and new attempt read as
independently live.

## Acceptance-audit adapter (built, #4992)

Acceptance audits used to bind one terminal attempt to one
`(issue, closeout_evidence_digest)` pair, with no retry — a deliberate
choice (partial-closeout-recovery, #4595) so a failed audit never loops
and so a stale digest cannot be rerun into a different answer. That was
correct for "the evidence didn't change," but it also meant an audit that
failed for an *infrastructure* reason (the `agent_harness` call itself
failed, not the evidence) had to wait for a new digest to get a second
try — the same gap `capacity_or_quota`/`worker_infrastructure`
classification closes for Apple verification. #4991 first bounded the
per-digest budget on the sweep; #4992 migrated the claim to this
contract. The adapter now landed:

- Keeps `(issue_id, closeout_evidence_digest)` as the **logical identity**
  — "what to verify" does not change; every execution attempt under it is
  one continuation request and run, so a fresh logical audit still needs
  new terminal evidence through ordinary admission.
- Carries an attempt-lineage dimension beneath that identity
  (`external_metadata["acceptance_audit_retry_attempt"]` /
  `"acceptance_audit_retry_of_agent_run_id"`, the metadata-key analogue of
  `AppleVerificationAttempt#retry_of_attempt_id`) so more than one
  execution attempt can occur under one evidence digest.
- Classifies audit failures
  (`PartialCloseouts::AcceptanceAuditFailure`: infrastructure/transient
  vs. a genuinely substantive assessment, cancellation,
  authentication/configuration, rate-limit recovery, budget exhaustion, or
  an indeterminate deterministic failure) **before** counting them against
  any attempt budget, mirroring Apple verification's
  failure-classification gate — never retrying "the evidence says no" as
  if it were "the call failed."
- Continues to record at most one *admissible* acceptance outcome per
  digest — the adapter retries the mechanism of reaching that outcome, not
  the evidence itself; a claim after the digest changed is refused
  (`evidence_changed`) so a stale retry cannot publish a current-looking
  result.
- Schedules through `RetryableAttempts::RetryAttempt` with
  `AgentRuns::AcceptanceAuditRetryPolicy` eligibility, but serializes the
  claim on the issue row lock (not an `AgentRun` unique index) because the
  path's identity — the continuation request's one-open-per-issue
  constraint — lives there.

That adapter is the migration this segment's matrix pointed at; its own
intent, EARS claims, and tests live in
`docs/intent/partial-closeout-recovery/` (PARTIAL-CLOSEOUT-056).

## Migration and rollout

**First implementation slice:** issue-less manual-run retry
(`docs/intent/manual-run-retry/`) is the reference adopter of the
mint-new-row half of this contract. `RetryableAttempts::RetryAttempt` owns
scheduling, locked claim, and durable decision recording;
`AgentRuns::ManualRunRetryPolicy` retains manual eligibility, lineage, and
successor construction. Timed-out `create_issue` and issue-owned Auto-Pick
`create_pr` retries adopt the same locked-claim mechanics while retaining
their operation-key identity, scheduling, admission, and decision policy.
Apple verification uses the same mechanics for a locked linked-row claim while
`AppleVerificationAttempts::RetryPolicy` retains its classification, queue,
per-run limit, immutable source, and lifecycle policy. In-place rate-limit
recovery remains deferred. The acceptance-audit adapter (#4992,
`docs/intent/partial-closeout-recovery/`, PARTIAL-CLOSEOUT-056) uses the
shared scheduler while retaining its evidence-owned, issue-locked claim and
ordinary audit-admission path.

**Rollback:** disable `Project#retry_failed_manual_runs` to stop new manual
retry scheduling. The service preserves the existing cap, backoff, input
copying, and locked recheck, so no other retry path is changed.

**Rollout guard:** the existing project-scoped
`retry_failed_manual_runs` setting remains the guard for this adopter.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Universal "replay AgentRun" operation | Rejected | A single `AgentRun#replay!` used by every path | Collapses meaningfully different identities (issue-owned vs. row-owned vs. digest-owned) and dispatch rules (mint vs. in-place vs. re-seed a parent) into one method; EAGER-QUEUE-007's issue-owned identity and rate-limit recovery's row-owned identity cannot share one claim method without one of them losing its own admission rule. |
| First migration slice | Issue-less manual-run retry | Timed-out-issue-goal retry; in-place rate-limit recovery | Smallest blast radius and a concrete mint-new-row adopter for validating shared mechanics without changing another path's identity. |
| New persisted state | None introduced | A shared `retry_attempts` table across every path | Every path's existing identity/lineage column (`external_metadata` keys, `retry_of_attempt_id`, `consecutive_auto_pick_failure_count`, `stale_requeue_count`) already covers attempt bookkeeping for that path; a shared table would duplicate data without adding capability. |
| Acceptance-audit multi-attempt support | `PartialCloseouts::RetryAcceptanceAudit` with `AgentRuns::AcceptanceAuditRetryPolicy`, built by the separate audit-recovery work (#4991 bounded the budget; #4992 migrated the claim onto this contract) | Continue documenting the extension point without implementing it | The audit adapter preserves its evidence-owned identity and ordinary admission path while using the shared policy/claim shape, avoiding duplicate retry coordination. |
| Shared interface as a shipped Ruby service | `RetryableAttempts::RetryAttempt` with manual-run, timeout-specific, issue-owned `create_pr`, Apple verification, and evidence-owned acceptance-audit policy adapters | A universal `AgentRun#replay!`; copied schedule/job predicates | Shared mechanics support AgentRun and Apple-attempt rows plus mint-a-row and issue-owned admission shapes while policy-owned admission avoids averaging incompatible identities and dispatch rules. |
| Timed-out issue-less retry identity | A persisted source-run operation key | Goal and prompt parameters | Equal prompt text can describe separate operator requests; a carried source-run key preserves one request's budget without conflating another's. Legacy rows lack that key, so the old heuristic is retained only for their transition attempt. |

## Open Questions & Future Decisions

### Deferred

1. Whether EAGER-QUEUE-007 needs its own `logical_identity`-shaped adapter
   note, since its identity owner (the issue) differs from every other
   path's identity owner (a row). This crosses into
   `docs/intent/eager-queue-seeding/`'s own territory and is flagged here
   rather than resolved, per LID's cross-segment cascade discipline.

## References

- `docs/intent/manual-run-retry/` — first implementation slice.
- `docs/intent/eager-queue-seeding/` — EAGER-QUEUE-007 (auto-picked
  `create_pr`/`analyze_issue` re-enqueue).
- `docs/intent/apple-verification-attempts/` — APPLE-ATTEMPT-010,
  APPLE-VERIFY-006.
- `docs/intent/partial-closeout-recovery/` — acceptance-audit
  evidence-digest behavior (#4595, #4223) and the retry adapter that
  migrated onto this contract (#4992, PARTIAL-CLOSEOUT-056).
- `docs/intent/temporal-orchestration/` — activity-level retry policy, the
  excluded layer below this contract's scope.
- `app/models/orchestration_decision.rb` — the durable decision-reason
  record reused by this contract.

*HLD:* `docs/high-level-design.md`.
