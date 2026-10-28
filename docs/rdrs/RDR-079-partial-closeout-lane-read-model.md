# RDR-079: Partial-Closeout Lane Read Model

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-10-28
- **Status**: Draft — proposed, pending owner ratification (#4558)
- **Type**: Architecture
- **Related RDRs**: [RDR-074](RDR-074-project-readiness.md) (the persisted project-readiness snapshot this read model mirrors), [RDR-032](RDR-032-eager-queue-seeding.md) (auto-pick admission authority)
- **Related Issues**: #4558 (this decision), #4120 (partial-closeout recovery umbrella), #4119 (gap ownership), #4556 (eligible-scope query optimization)

## Problem

The `partial_closeout` Inbox lane derives its membership from live auto-pick
admission. `Issues::StalledCloseouts` asks
`Automation::Strategies::AutoPick::DefaultCandidateSource.partial_closeout_eligibility`,
which evaluates the ordinary `eligible_scope` for a project's candidates and
then evaluates the scoped-continuation `eligible_scope` for the candidates the
ordinary scope excluded. `DefaultCandidateSource.eligible_scope` remains the
canonical admission decision for auto-pick, dequeue recheck, and continuation
admission, and it stays that way under this proposal.

Three Inbox consumers call `Issues::StalledCloseouts` independently:

| Consumer | When it runs | Cached |
| --- | --- | --- |
| `Inbox::Queue#partial_closeout_entries` | every Inbox index render | no |
| `Inbox::Count#partial_closeout_count` | nav badge | yes — 90 s TTL behind the account's `inbox` `Dashboard::CacheVersion` |
| `Inbox::Availability#partial_closeout_by_project` | filter matrix | yes — 90 s TTL behind the same version |

The lane therefore evaluates live admission on the request path, and the cost
grows with the number of projects that have closeout candidates rather than
with the number of stalls.

### Measured cost

`script/inbox/measure_partial_closeout_lane.rb` measures the request path
against a migrated database with tenant row-level-security policies enabled
(114 policies) and a runtime role that does not bypass RLS. The recorded run
is `docs/performance/partial-closeout-lane-2026-10-28.json`.

| Projects with a stall | `eligible_scope` evaluations per consumer | SQL statements per consumer | SQL time per consumer |
| --- | --- | --- | --- |
| 1 | 2 | 24–32 | 0.02–0.2 s |
| 5 | 10 | 140–161 | 0.8–1.0 s |
| 10 | 20 | 275–296 | 1.8–2.0 s |
| 20 | 40 | 545–566 | 3.5–5.2 s |

Two facts drive the cost:

- **Two admission evaluations per project.** `partial_closeout_eligibility`
  evaluates the ordinary scope and, for the issues that scope excluded, the
  scoped-continuation scope. Batching inside one invocation keeps the cost flat
  in the number of candidates (`PARTIAL-CLOSEOUT-026`); it does not remove the
  per-project cost.
- **Planning dominates the admission statement.** The eligibility SQL is
  5,211 bytes and took 23–32 ms to plan against 2–7 ms to execute. The tenant
  policies add roughly 1–3 ms of planning to that statement and under 0.1 ms
  to a trivial `issues` statement, so the statement's own shape — the
  `NOT EXISTS` / `IN` subqueries over `issues`, `agent_runs`, `issue_dependencies`,
  `notifications`, `feature_intent_issues`, and `model_selections` — is the
  dominant term.

The three consumers also repeat each other's work: for 20 projects the badge
issued 560 statements and the filter matrix 563, each independently issuing the
same 40 admission evaluations.

## Decision (proposed)

Paid SHALL read the lane's membership from a persisted, display-only stall
projection instead of evaluating live admission on the Inbox request path.

The projection is a read model, not a second admission authority:

- `DefaultCandidateSource.eligible_scope` remains the canonical admission
  decision for auto-pick selection, dequeue recheck, continuation preflight,
  and run start. Nothing in this proposal changes those call sites.
- The projection records which issues are stalled and why. It never grants a
  continuation, never mutates `paid_state`, and never stands in for the
  scoped admission decision that `Issues::RequestContinuation` preflights and
  `AgentRuns::RecheckIssueEligibility` re-applies at dequeue.
- An operator action taken from a projected lane entry is refused by the live
  preflight with the real blocker if the projection is stale, so a stale
  projection can cost the operator a click but can never schedule unauthorized
  work.

### Read model

The projection is stored per project, matching the unit the lane already
batches on, and carries one row per stalled issue:

| Field | Meaning |
| --- | --- |
| `project_id` | the owning project |
| `issue_id` | the stalled issue |
| `evidence_digest` | the outcome-generation digest the stall was computed against |
| `status` | the recorded outcome and the reason continuation cannot proceed |
| `blockers` | the additive structured blockers `CloseoutStatus` produces |
| `computed_at` | when the projection was last recomputed |

A project with no stalled issue has no rows; the absence of rows is the
"nothing is stalled" answer, and a stale row is removed by the recomputation
that supersedes it.

### Triggers

Recomputation is event-driven, not polled, and covers every input that changes
admission or lane membership:

- closeout evidence changes (a merged PR linked to the source issue, a
  no-code-required outcome, a new evidence generation),
- an agent run starting, finishing, or being cancelled,
- an `IssueContinuationRequest` opening, closing, or being superseded,
- an explicit hold (a skip label, a needs-input label, a pause, a
  `needs_input` / `manual_review` state, a retry abandonment, a design
  amendment hold, a code-scanning verification attempt),
- admission-relevant runner configuration (the tier feasibility set),
- feature-intent release and design-revision state.

A project-level sweep recomputes any project whose inputs changed since its
last projection, so a missed trigger self-heals rather than stranding a stall.

### Freshness and failure semantics

- The projection is advisory about *presence* and *reason*; the live preflight
  is authoritative about *admission*.
- A recomputation that fails leaves the previous projection in place and
  records the failure; it never deletes rows on failure.
- A recomputation that succeeds removes the rows for issues that are no longer
  stalled, so the lane never shows an issue the live scope would admit.
- The projection records `computed_at`, so a consumer can distinguish "no
  stall" from "not evaluated yet".

### Tenant isolation

The projection is read through the same tenant-scoped relations as the rest of
the Inbox, so a project in another account is never visible. Recomputation
runs under the owning account's tenant context.

### Shared read path

`Inbox::Queue`, `Inbox::Count`, and `Inbox::Availability` read one shared
projection reader, so the lane list, the nav badge, and the filter matrix can
never disagree about whether an issue is stalled. The reader performs no
`eligible_scope` evaluation.

## Rollout Guard

The proposal ships behind a `FeatureFlags` key, `partial_closeout_lane_read_model`,
defaulting to off. While it is off the lane keeps evaluating live admission.
Enablement is per project, matching how `Automation::RolloutGuard` exposes
other staged behaviors. Rollback is disabling the flag, which restores the
live path with no schema change and no data migration of operator-visible
state. The key is added to `FeatureFlags::DEFINITIONS` by the implementation
issue, not by this proposal.

## Validation criteria

- An Inbox index render for an operator whose projects have stalls issues no
  `eligible_scope` evaluation, and the lane's entries match the projection.
- `Inbox::Queue`, `Inbox::Count`, and `Inbox::Availability` report the same
  membership for the same operator.
- A continuation requested from a projected lane entry is still decided by the
  live scoped preflight, and a refusal names the real blocker.
- A run that starts on a stalled issue removes the issue from the lane after
  the recomputation, and a run that completes with new terminal evidence adds
  it.
- A failed recomputation keeps the previous projection and does not delete
  rows.
- Another account's project never appears in the projection or the lane.

## Alternatives considered

### Option A — keep live admission (status quo)

Rejected as the steady state, retained as the pre-proposal behavior. It keeps
a single authority and no stale-state contract, but it leaves Inbox latency
coupled to admission complexity, and the measurement above shows that coupling
grows linearly with the number of projects that have closeout candidates.

### Option C — cache the `StalledCloseouts` result per project

Rejected. The account's `inbox` cache version moves on a narrow set of
transitions (needs-input and manual-review timestamps, retry abandonment,
closeout resolution, merge-approval and test-review fields, notifications,
continuation requests, feature intents, change intents, and some project
settings). It does not move when an agent run starts or finishes, when a
merged PR is synced, when a skip label changes, when a design-amendment hold
is applied, or when runner configuration changes the tier feasibility set.
A cache behind that boundary is correct only if those transitions also bump the
version, which is the same invalidation surface the projection needs; and
until they do, the lane list would serve badge-grade staleness — an item that
no longer qualifies, or a stall that has not appeared yet — where today only
the badge is stale. A correct Option C is therefore neither cheaper than the
projection nor better for the operator.

### Persist the lane's membership as Inbox items

Rejected, consistent with the segment's existing decision that the lane
derives from evidence columns. Persisted lane items would need their own
creation, expiry, and dismissal lifecycle and would duplicate the projection's
purpose.

## Trade-offs

The projection adds a durable derived record that can disagree with live
admission for a bounded window. That window is the cost of moving the work off
the request path; the live preflight and dequeue recheck bound its blast
radius to operator experience rather than to unauthorized work. The projection
also adds a recomputation path that must cover every admission input, which is
the same coverage Option C would need and the main implementation risk.

## Open owner decision

This RDR is **proposed, not accepted**. The owner must choose between Option A
(status quo), Option B (this proposal), and Option C (per-project cache) before
implementation begins. Until then the lane keeps live admission, no projection
table exists, and no runtime behavior changes.
