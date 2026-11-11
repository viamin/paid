---
parent: PAID
prefix: AGENT-RETRY
---

# Low-Level Design: Agent Run Retry Contract

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment names the shared vocabulary and minimal interface shape for
> "another attempt at the same logical operation" across Paid's existing
> retry (and deliberate no-retry) paths for agent runs and agent-run-style
> attempts (#4986). It is a map and a contract, not a new runtime
> subsystem: every path named below keeps its own owner, identity, and
> dispatch logic exactly as it stands today.

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
# Documented shape only — no module ships with this change. A future
# migration slice may introduce a real module once a second or third path
# adopts it; see "Migration and rollout" below.
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
| Timed-out `create_issue` | `RetryTimedOutIssueGoalJob` | `(project, issue_id)` when issue-attached, else `(project, goal, runner, agent_type, custom_prompt, source_pull_request_number)` | Mints a new `AgentRun` (or marks an existing active sibling retried on a unique-index race), budget 3 (`MAX_RETRIES`), counts prior `timeout`/`retried` rows for the same identity, records the decision via `AgentRun#retry!` | Budget reached; an existing active run already claims the identity's unique slot | Later — same mint-new-row shape and lock-recheck as manual-run-retry; a candidate second slice once a second concrete adopter is scoped, tracked separately from this issue. |
| Auto-picked `create_pr`/`analyze_issue` (issue-driven) | `Issue#enqueue_self_if_became_auto_pick_eligible` → `Issues::ReenqueueEligibleJob` (`docs/intent/eager-queue-seeding/`, EAGER-QUEUE-007) | `issue_id` — the *issue* carries the retry-chain state (`consecutive_auto_pick_failure_count`), not a terminal row | No attempt row is minted ahead of time: the issue re-enters the eligibility queue and `Issues::EnqueueEligible` mints the `AgentRun` only when a scheduler actually claims it. Backoff `(n**4)+15+jitter` (no numeric cap); effectively bounded by parking the issue in the retry-limited Inbox once the effective retry cap is reached | Issue no longer eligible; retry-limited Inbox parks the issue; `auto_pick_enabled` off | Later — identity owner is the issue, not a row, so adoption needs its own adapter note in `docs/intent/eager-queue-seeding/` (cross-segment; not resolved here, see Open Questions). |
| In-place rate-limit recovery | `StaleRunDetectorJob#recover_rate_limited_run` | The same `AgentRun` row (`status: "rate_limited"`, `rate_limited_until` elapsed) | No new row — in-place re-queue under row lock, budget via `stale_requeue_count` against `AgentRun::MAX_RATE_LIMITED_REQUEUES`, admission recheck via `active_sibling_exists?`, capacity-parked attempts exempt from budget decrement | Budget exhausted → terminal `failed`; active sibling already owns the identity's unique slot → terminal `failed`, superseded | Later — already in-place-attempt-shaped; a natural second reference for the in-place half of the contract (as opposed to manual-run-retry's mint-new-row half), tracked separately. |
| Temporal activity recovery | Temporal server + `AgentExecutionWorkflow`'s per-activity `RetryPolicy` (e.g. `RUN_AGENT_RETRY_POLICY`, `max_attempts: 2`) | The in-flight workflow execution / activity task — not an `AgentRun` | Infra-only re-invocation of the *same* activity call inside one logical attempt (worker crash, heartbeat timeout); application errors are marked `non_retryable` in the activity itself | `max_attempts` exhausted → activity failure propagates to `MarkAgentRunFailedActivity`, which is where this contract's scope begins | **Not migrated — different layer**, named here only so it is not mistaken for an unmapped gap (see Scope and non-goals). |
| Acceptance audits | Acceptance-audit sweep / `PartialCloseouts::Advance` (`docs/intent/partial-closeout-recovery/`, #4595) | `(issue_id, closeout_evidence_digest)` | Deliberately **not retried**: at most one automatic audit attempt per issue and evidence digest, including terminal attempts, so a failed audit never loops. A new digest (new merged PR, or a no-code outcome) earns exactly one new audit | Any terminal attempt recorded for the current digest; digest unchanged | **Out of scope for this issue.** No acceptance-audit runtime file is touched by this change. See "Acceptance-audit adapter" below for the documented extension point the separate audit-recovery work can land on. |
| Apple verification attempts | `AppleVerificationAttempts::RetryMonitor` + `AppleVerificationRetryJob` (`docs/intent/apple-verification-attempts/`, APPLE-ATTEMPT-010) and the rerun flow (APPLE-VERIFY-006) | `retry_of_attempt_id` lineage to the terminal source attempt, scoped by `agent_run_id` | An idempotent queued retry bound to its terminal source attempt; retries only infra-classified failures (`capacity_or_quota`, `worker_infrastructure`, `cancellation_or_timeout`), bounded by a configurable retry limit and queue depth; `idx_apple_attempts_one_active_per_run` enforces one active attempt per run | Non-infra failure classification (deterministic project failure); retry limit reached; queue depth cap | Later — same shape (lineage column + bounded retry + failure-classification gate) as the contract's "mint a linked row" half; a candidate third reference once a second slice is scoped, tracked separately. |
| `bootstrap_readiness` (explicit operator policy) | `AgentRun#bootstrap_readiness_goal?` exclusion inside `Activities::MarkAgentRunFailedActivity#manual_run_retry_eligible?`; PROJECT-READINESS-007 | `(project, bootstrap_readiness goal)` | **No automatic retry of any kind.** A failed bootstrap run stays terminal until an operator explicitly starts a replacement from the project-setup Inbox entry | N/A — only an explicit operator action unblocks it | **Must not be migrated.** No adoption of the shared shape may silently add automatic retry to this path; its absence of retry is the policy, not a gap. |

## Cross-cutting safety requirements

Any path that adopts the shared interface shape — and every path in the
matrix above already satisfies these, which is how the matrix was built —
must hold the following, each grounded in an existing exemplar:

- **Duplicate jobs.** Re-check attempt eligibility under a row lock
  immediately before claiming, not only at schedule time, so a duplicated
  or re-delivered delayed job cannot double-claim. (`RetryFailedManualRunJob#perform`'s
  `AgentRun.lock.find_by` re-check; `RetryTimedOutIssueGoalJob#perform`'s
  locked re-check; `StaleRunDetectorJob#recover_rate_limited_run`'s
  `with_lock`.)
- **Concurrent schedulers.** The claim is a single atomic transaction keyed
  off a unique index or row lock, and a losing concurrent claim recognizes
  its specific conflict and resolves to a no-op rather than an unhandled
  error. (`idx_agent_runs_unique_active_lid_planning` handling in
  `RetryFailedManualRunJob`; `idx_agent_runs_unique_active_issue`/`_pr`
  handling in `RetryTimedOutIssueGoalJob`'s `RecordNotUnique` rescue;
  `idx_apple_attempts_one_active_per_run`.)
- **State changes during backoff.** Eligibility is re-evaluated against
  current state at claim time, never trusted from schedule time — a
  toggle flipped, another run claiming the slot, or the run already being
  retried must all be visible to the claim, not just the schedule.
  (Same locked re-checks as above.)
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
  `AgentRun::MAX_RATE_LIMITED_REQUEUES`, Apple verification's retry limit
  and queue-depth cap, acceptance audit's one-attempt-per-digest cap.)
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
- The issue/PR identity columns on `AgentRun` itself, read by
  `RetryTimedOutIssueGoalJob#count_previous_retries`.
- `Issue#consecutive_auto_pick_failure_count` (EAGER-QUEUE-007).
- `AgentRun#stale_requeue_count` (in-place rate-limit recovery).
- `AppleVerificationAttempt#retry_of_attempt_id` (Apple verification).
- The `(issue_id, closeout_evidence_digest)` pair recorded on the acceptance
  audit's continuation request (partial-closeout-recovery).

Durable decision reasons reuse `OrchestrationDecision` (`project`, `issue`,
`agent_run`, `decision_point`, `action`, `status`, `signals`, `result`),
already the mechanism `AgentRun#retry!` →
`AgentRun#log_orchestration_decision` writes to for both manual-run-retry
and the timed-out-issue-goal path. Acceptance audits record their
equivalent durable reason as an audit event on the partial-closeout
reconciliation record rather than `OrchestrationDecision`, because their
decision is about evidence sufficiency, not an execution retry — this
segment does not require unifying those two record types.

## Cancellation and side-effect safety

A superseded attempt's terminal marking and the next attempt's creation
happen inside the same lock, never as two separate writes: `AgentRun#retry!`
updates `status: "retried"` and writes the `OrchestrationDecision` in one
`with_lock` block, and every mint-new-row path in the matrix marks the
original superseded before (or atomically with) creating the replacement.
This prevents a window where both the old and new attempt read as
independently live.

## Acceptance-audit adapter (future)

Acceptance audits currently bind one terminal attempt to one
`(issue, closeout_evidence_digest)` pair, with no retry — a deliberate
choice (partial-closeout-recovery, #4595) so a failed audit never loops
and so a stale digest cannot be rerun into a different answer. This is
correct for "the evidence didn't change," but it also means an audit that
fails for an *infrastructure* reason (the `agent_harness` call itself
failed, not the evidence) currently has to wait for a new digest to get a
second try — the same gap `capacity_or_quota`/`worker_infrastructure`
classification closes for Apple verification.

Once the separate audit-recovery work lands, an adapter conforming to this
contract can:

- Keep `(issue_id, closeout_evidence_digest)` as the **logical identity**
  — "what to verify" does not change.
- Add an attempt-lineage dimension beneath that identity (the same shape
  as `AppleVerificationAttempt#retry_of_attempt_id`) so more than one
  execution attempt can occur under one evidence digest.
- Classify audit failures (infrastructure vs. a genuinely inconclusive or
  deterministic result) **before** counting them against any attempt
  budget, mirroring Apple verification's failure-classification gate —
  never retrying "the evidence says no" as if it were "the call failed."
- Continue to record at most one *admissible* acceptance outcome per
  digest — the adapter retries the mechanism of reaching that outcome, not
  the evidence itself.

This issue does not build that adapter and changes no acceptance-audit
runtime file; it only names the extension point so the separate work has a
documented landing spot.

## Migration and rollout

No runtime behavior changes in this PR. Every path in the policy matrix
keeps its current owner, identity, budget, and dispatch logic exactly as
shipped.

**First implementation slice:** issue-less manual-run retry
(`docs/intent/manual-run-retry/`) is declared the reference adopter of the
mint-new-row half of this contract. It already satisfies every
cross-cutting safety requirement above without modification, so adopting
it as the first slice requires no code change — only this design's
cross-reference. Timed-out-issue-goal retry, in-place rate-limit recovery,
and Apple verification attempts are named as candidate second/third slices
(one mint-new-row-shaped, one in-place-shaped, one lineage-column-shaped)
but are explicitly deferred to their own tracked follow-up work.

**Rollback:** since this change ships no runtime code, there is nothing to
roll back. A future extraction PR that introduces a real
`Retryable::AttemptPolicy` module must keep every adopted use case's
existing specs green — the same "this feature SHALL NOT alter X" regression
shape `MANUAL-RUN-RETRY-007` already uses against EAGER-QUEUE-007 and
`StaleRunDetectorJob`.

**Rollout guard:** Docs-only. This change exposes no runtime behavior; a
future extraction PR picks its own guard (feature flag, config gate, or
migration-only) scoped to whichever path it migrates, per
`docs/rdrs/README.md`'s Rollout Guard taxonomy.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Universal "replay AgentRun" operation | Rejected | A single `AgentRun#replay!` used by every path | Collapses meaningfully different identities (issue-owned vs. row-owned vs. digest-owned) and dispatch rules (mint vs. in-place vs. re-seed a parent) into one method; EAGER-QUEUE-007's issue-owned identity and rate-limit recovery's row-owned identity cannot share one claim method without one of them losing its own admission rule. |
| First migration slice | Issue-less manual-run retry | Timed-out-issue-goal retry; in-place rate-limit recovery | Already shipped, already satisfies every cross-cutting requirement in this design, smallest blast radius, and explicitly named by the issue scoping this design. |
| New persisted state | None introduced | A shared `retry_attempts` table across every path | Every path's existing identity/lineage column (`external_metadata` keys, `retry_of_attempt_id`, `consecutive_auto_pick_failure_count`, `stale_requeue_count`) already covers attempt bookkeeping for that path; a shared table would duplicate data without adding capability. |
| Acceptance-audit multi-attempt support | Documented extension point only, not implemented | Implement the adapter now | Acceptance-audit recovery is explicitly separate, in-progress work (per issue scope); this design intentionally stops at naming the landing spot so that work is not duplicated or pre-empted here. |
| Shared interface as a shipped Ruby module | Documented shape in this design only, no module added | Ship `Retryable::AttemptPolicy` now with no caller | A module with no adopter is dead code; the interface earns its place in code once a second concrete use case migrates to it (tracked separately), not before. |

## Open Questions & Future Decisions

### Deferred

1. Whether `RetryTimedOutIssueGoalJob` and the Apple verification retry
   monitor should be refactored onto a literal shared Ruby interface, or
   whether documenting the shape (as done here) remains sufficient —
   decide when the second migration slice is actually scoped.
2. Whether EAGER-QUEUE-007 needs its own `logical_identity`-shaped adapter
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
  evidence-digest behavior (#4595, #4223).
- `docs/intent/temporal-orchestration/` — activity-level retry policy, the
  excluded layer below this contract's scope.
- `app/models/orchestration_decision.rb` — the durable decision-reason
  record reused by this contract.

*HLD:* `docs/high-level-design.md`.
