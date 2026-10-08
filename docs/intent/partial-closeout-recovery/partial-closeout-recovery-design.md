# LLD: Partial-Closeout Recovery

```yaml
parent: operator-inbox
prefix: PARTIAL-CLOSEOUT
```

## Problem

Auto-pick eligibility guards are deliberately `paid_state`-independent: once a
merged PR row is authoritatively linked back to a source issue
(`EAGER-QUEUE-011`) or an agent declares a no-code-required completion
(`AUTO-PICK-QUEUE-004`), the issue stays out of selection forever regardless of
internal state. That is the correct duplicate-work default, but an issue whose
merged PR intentionally did not close it (no closing reference) and whose
follow-up work could not be filed or completed disappears from every
actionable surface: it is in no Inbox lane, no lifecycle bucket, and re-setting
`paid_state` does not lift the guard. Operators currently need
database-level investigation to distinguish completed work from a stranded
partial closeout (#4120; examples #3860, #3861, #3871, #3930, #4013).

## Scope

Companion workstreams, not prerequisites: #4118 (automatic continuation after
merged partial PRs) and #4119 (gap ownership / follow-up filing). This segment
delivers visibility + authorized recovery on its own.

## Design

### Evidence: `Issues::CloseoutEvidence`

One value object computes the *closeout evidence* for an issue and a stable
*outcome-generation digest*:

- merged PR rows linked via `parent_issue_id` (`pr_review_phase = "merged"`),
- merged PR rows matched to an originating `create_pr` run's recorded
  `pull_request_number` (repo-qualified URL join, same discipline as
  `Issue.paid_generated_pull_request_source_issue_ids`),
- `issues.no_code_required_at` (terminal-run evidence).

Terminal timestamps use `agent_runs.completed_at` (falling back to the PR
row's `created_at`) — never `updated_at`, matching the immutability rationale
of `merged_pr_terminal_audit_at_by_issue_id` in the auto-pick candidate
source. The digest is a SHA-256 of the canonical evidence list (PR numbers +
terminal times + no-code timestamp), so any *new* terminal outcome is a new
generation.

### Visibility: the `partial_closeout` Inbox lane

Derived lane (like `retry_limited`), not persisted state. An open, non-PR
issue is in the lane when it carries closeout evidence, is *not* admitted by
`eligible_scope` (i.e. the guards are what holds it — epic re-arm under
`AUTO-PICK-QUEUE-010` means it is not stalled), has no explicit operator hold
(issue `paused`, auto-pick skip labels, `needs_input` label,
`paid_state` in `needs_input`/`manual_review`, retry abandonment — those are
deliberate operator or lane states, not stalls), has no work in flight
(blocking run or open continuation request), and is not resolved-complete
against the current evidence generation. The detail pane shows the source
PR/run links, the recorded completion outcome, unresolved prerequisites
(blocking dependencies), and the exact reason automatic continuation cannot
proceed.

### Recovery: `IssueContinuationRequest` (scoped authorization)

A deliberate continuation is a persisted, auditable authorization — never a
paid_state edit and never a blanket guard lift:

- `requested_by_id` (actor), `reason` (required), evidence snapshot +
  `evidence_digest` (outcome-generation identity).
- One *open* request per issue (partial unique index `WHERE status='queued'`);
  the request and its queued run are created in one transaction, so
  double-clicks, replays, and concurrent requests queue at most one run (the
  `idx_agent_runs_unique_active_issue` index is the second guard).
- `agent_runs.continuation_request_id` links the run to its authorization; when
  the run reaches a terminal status the request is `consumed` and the guards
  re-arm — an issue is deliberately continued *once* per request.
- Admission validation reuses `DefaultCandidateSource.eligible_scope` with a
  new `continuation_authorized_issue_ids` parameter that lifts **only** the
  merged-PR and no-code guards for the authorized issue. Active-run
  uniqueness, tenant isolation, trust, feature release/design revision holds,
  analysis backoff, tier feasibility, budgets, skip labels, needs-input,
  manual review, paused flags, and unmet dependencies all still apply — with
  the unmet prerequisites explained to the user. A targeted blocker walk
  (`CloseoutStatus.admission_blockers`) returns structured, additive reasons
  from persisted admission-guard evidence, including scanner attempt, analysis,
  and alert links for synthetic findings; a residual preflight then settles admission with the
  exact scoped `eligible_for_dequeue?` decision the dequeue recheck enforces
  (batched once per project in `StalledCloseouts`), so a request the walk
  cannot determine is labelled unavailable with an investigation path rather
  than a guessed guard, and is refused up front instead of queueing a run dequeue would
  cancel and supersede — the walk explains the authority, it never
  substitutes for it.

### Prompt delivery

The authorization is useless to the executing agent if it never reaches the
prompt: `PromptAssembly::Sections::ContinuationContext` reads
`agent_run.continuation_request` and, when present, contributes a required
"Continuation Context" section carrying the operator's reason, the evidence
snapshot the request was authorized against, the evidence-generation digest,
and guidance (treat the reason as the remaining-work plan; do not re-verify
already-evidenced work; do not treat closed child issues as sufficient
evidence for an epic; leave the issue/epic open if the named scope is not
fully resolved). Both the Inbox action and the `request_issue_continuation`
MCP tool create the run through the same `Issues::RequestContinuation`
transaction, so this section covers both uniformly without branching on
request origin. The section is required (never suppressed by profile
customization) but contributes nothing for ordinary runs, and rebuilding the
prompt (Temporal activity replay) is idempotent — it does not duplicate the
section.

### Consistency at dequeue and run start

`AgentRuns::RecheckIssueEligibility` gains a continuation branch (continuation
runs are manual-trigger, so the auto-pick recheck never applied to them): a
queued continuation run is cancelled and its request `superseded` when the
request is no longer open, the evidence generation changed, the issue lost
admission under the scoped lift, or the project is explicitly paused.
`ProcessRunQueueJob` already rechecks every candidate before claim, keeps the
budget check (`CostBudgets::Check`) and feature-intent admission at run start.

### Resolve-complete (evidence-gated dismissal)

`Issues::ResolveCloseout` records the operator's attestation that the recorded
evidence completes the issue: stamps `closeout_resolved_at`,
`closeout_resolution_digest` (the generation it resolves), and the actor, sets
`paid_state = completed`, and leaves the GitHub issue open. The lane item is
suppressed while the digest matches; new terminal evidence is a new
generation and re-creates the item. Repeated sync cannot recreate a
dismissed/resolved item without new evidence because nothing is persisted by
sync for this lane — it is derived from evidence, and the dismissal is
digest-scoped. Resolution takes the issue lock shared by continuation creation,
supersedes any open authorization, and cancels its unclaimed queued run before
recording completion, so a continuation cannot dispatch after the attestation.

### Surfaces

- Inbox: `Inbox::Queue`/`Inbox::Count` lane + `partial_closeout` detail pane
  with authorized actions (request continuation, resolve complete, guidance
  for prerequisite work), a contextual chat action which retrieves current
  evidence and recovery state without mutating it, and `Inbox::Count` badge
  invalidation on the new transitions.
  The required continuation reason has a persistent
  label and a multi-line input that fills the available pane width. Its submit
  button sits on a separate row, so a narrow detail pane never clips either
  control.
- Controller: `request_continuation` and `resolve_closeout` collection routes
  on `projects/agent_runs` (authorize `:run_agent?`, audit events,
  stale-click resolvers) — same shape as `OPERATOR-INBOX-002C/002D/002E`.
- MCP: `request_issue_continuation` and `resolve_issue_closeout` tools calling
  the same services with the same policy and audit behavior. Prerequisite
  work reuses the existing `create_issue` tool (dependency wording is parsed
  by the existing sync parser).

## Alternatives considered

- *Lift the merged-PR guard via paid_state*: explicitly rejected — the guard is
  deliberately state-independent (#3432/#3588 review follow-up).
- *Blanket "clear blocker" action*: rejected by the issue; recovery actions are
  scoped (one continuation per request against one evidence generation).
- *Persisted inbox items*: the lane derives from evidence columns like
  `retry_limited` does; only the scoped authorization and the resolution
  dismissal are persisted.
