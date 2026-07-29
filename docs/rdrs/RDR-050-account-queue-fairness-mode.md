# RDR-050: Account-Level Queue Fairness Mode — Strict Priority vs. Cross-Project Fair Share

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-07-29
- **Status**: Draft
- **Type**: Architecture
- **Priority**: P1
- **Related Issues**: TBD (file against this RDR before implementation)
- **Related RDRs**: RDR-047 (Work-Category Queue Priority — treats cross-project fairness as a fixed requirement; this RDR makes it configurable), RDR-032 (Eager Queue Seeding — made `QUEUE_ORDER` the sole ordering mechanism), RDR-031 (Focused Agent Runs — introduced the project/user fair-stride keys)
- **Related PRs**: [#3065](https://github.com/viamin/paid/pull/3065) (display-only fair-share preview — the upcoming-queue UI this RDR must keep consistent)

## Problem Statement

Cross-project fair-share is the **primary** queue sort key today (`AgentRun::PROJECT_ACTIVE_COUNT_SQL`, `app/models/agent_run.rb:1180`), ahead of priority. As `QUEUE_ORDER` (`agent_run.rb:1191`) and its comment (`:1183`–`:1190`) make explicit: *"project_active_count → cross-project round-robin … queue_priority → strict priority within a project."* The practical effect is that **a P1 run in a busy project can sit behind a P3 run in an idle project**, because priority only resolves ties *within* the same per-project in-flight count.

Some accounts want the opposite — **strict global priority**, where a P1 anywhere beats a P3 everywhere, accepting that a high-volume project may starve lower-priority work elsewhere. Today there is no way to express that preference:

- A toggle meant to control this (`user_settings.fair_queue_across_projects`, added 2026-04-21) was **never wired into the ordering or exposed in the UI** and had zero effect. It has been removed (short-term cleanup) — see the prerequisite below.
- The ordering is hardcoded as frozen constants in three places: `QUEUE_ORDER`, `SCHEDULER_QUEUE_ORDER` (`agent_run.rb:1191`, `:1202`), and `queue_order_display` (`:1245`).

Requirements (from stakeholder review):

- The choice between fair-share and strict-priority dequeue must be **account-scoped**, not per-user. Fairness is inherently a property of the *project pool* an account owns; two members of the same account selecting contradictory fairness modes is incoherent — they share one scheduler and one queue view.
- The setting must affect **both** the scheduler dequeue and the upcoming-queue display, so what users see matches what the scheduler does (the explicit goal of PR #3065).
- Default behavior (fair-share) must not change for existing accounts.

## Context

### Two independent fairness layers

Fairness is enforced in **two** places, and a complete solution must address both:

1. **SQL dequeue ordering** — `AgentRun.peek_next_queued_run` / `claim_next_queued_run` → `next_queued_run_from` (`agent_run.rb:1336`–`:1378`) `.reorder(SCHEDULER_QUEUE_ORDER)`. `project_active_counts_cte` (`:1294`) and `user_active_counts_cte` (`:1305`) compute per-project / per-owner in-flight counts (running + claimed-queued) that drive the round-robin.
2. **Temporal worker fairness** — `ProcessRunQueueJob#temporal_priority_for` (`app/jobs/process_run_queue_job.rb:915`) sends a `Temporalio::Priority` with `priority_key` = the run's queue tier and `fairness_key = account_id` (`:922`–`:924`). Temporal's own task scheduling honors that fairness key, independent of the SQL ordering.

> **Subtlety:** fixing only the SQL ordering does not guarantee absolute priority end-to-end. If the Temporal worker pool is the binding constraint (workflow-start scheduling), Temporal's per-`account_id` fairness key re-imposes fair-share after Paid has claimed a run. A strict-priority mode must therefore also neutralize the Temporal fairness key (e.g., a constant key) or confirm that Paid's claim ordering is authoritative because Temporal immediately admits the claimed workflow.

### Account-level configuration home

Account-scoped settings live on `tenant_settings` (model `TenantSetting`). It already holds analogous scheduler knobs as dedicated columns — `max_concurrent_runs`, `max_concurrent_create_pr_runs` — alongside jsonb blobs (`agent_settings`, `features`, `guardrails`). A queue-fairness mode belongs here, not on `user_settings`.

### Related prior decisions

- **RDR-047** deliberately *preserved* `PROJECT_ACTIVE_COUNT_SQL` / `USER_ACTIVE_COUNT_SQL` as the first `QUEUE_ORDER` keys and stated project-level fairness as a hard requirement. This RDR does not contradict RDR-047; it makes the fairness-first behavior one of two selectable modes (and the default).
- **RDR-032** made `max_concurrent_runs` + `QUEUE_ORDER` the sole capacity/ordering mechanism; this RDR keeps that invariant (capacity gating in `Capacity::RunAdmission` is untouched).
- **PR #3065** replays the fair-share dispatch order in `Dashboard::QueuePreview` so the upcoming-queue preview matches the scheduler. Any mode toggle must be applied there too, or the preview will mislead users in strict-priority accounts.

### Prerequisite (DONE as part of this change)

Removed the dead `user_settings.fair_queue_across_projects` column (migration `20260729183603_remove_fair_queue_across_projects_from_user_settings`). It was added with the intent of this very toggle but never implemented, and leaving an inert, misleading setting in place was worse than removing it. **Any reintroduction must be account-scoped on `tenant_settings`** — see Proposed Solution.

## Proposed Solution

### Core Idea

Add an **account-level** `queue_fairness_mode` on `tenant_settings` with two values:

| Mode | Behavior | Default |
|------|----------|---------|
| `fair_share` | Current behavior: `project_active_count` / `user_active_count` sort first; priority resolves ties within a project. Prevents one project from starving others. | ✅ yes |
| `strict_priority` | `queue_priority` is the primary key globally; the active-count keys are dropped from the order. A P1 anywhere dequeues ahead of a P3 everywhere, at the cost of possible cross-project starvation. | — |

### Schema

Add a dedicated column (matches the `max_concurrent_*` pattern — queryable, explicit, validated by a CHECK constraint):

```ruby
add_column :tenant_settings, :queue_fairness_mode, :string, limit: 20,
  default: "fair_share", null: false,
  comment: "Account dequeue policy: fair_share (round-robin across projects) or strict_priority (global priority order)."
add_check_constraint :tenant_settings, "queue_fairness_mode IN ('fair_share','strict_priority')",
  name: "chk_queue_fairness_mode"
```

### Mode-aware ordering

Replace the hardcoded `QUEUE_ORDER` / `SCHEDULER_QUEUE_ORDER` / `queue_order_display` reorder with a method that returns the key set for the resolved mode, e.g. `AgentRun.queue_order_for(mode:)`:

- `fair_share` → the current key list (unchanged).
- `strict_priority` → `QUEUE_PRIORITY_SQL` promoted to first, `PROJECT_ACTIVE_COUNT_SQL` / `USER_ACTIVE_COUNT_SQL` omitted. `IN_PROGRESS_SQL`, `GOAL_PRIORITY_SQL`, FIFO tiebreakers remain.

**Threading the mode:** the ordering scopes currently resolve at the class level without knowing the account. The cleanest seam is to pass the mode (or the resolved `TenantSetting`) into the dequeue entry points:

- `peek_next_queued_run` / `claim_next_queued_run` — called from `ProcessRunQueueJob`, which already resolves the account/user per pass.
- `queue_order_display` — called from the controller, where the current account is available.

The `*_active_counts` CTEs can remain as LEFT JOINs (harmless when the sort key is absent) or be skipped in strict mode for a small query-planner win.

### Temporal fairness key

`temporal_fairness_key_for` (`process_run_queue_job.rb:922`) returns `account_id.to_s`. In `strict_priority` mode, collapse it to a constant (e.g., `"strict"`) so Temporal does not re-impose per-account fair-share. This must be validated against actual Temporal worker behavior during implementation (confirm whether the SQL claim or Temporal admission is the binding constraint) — see Risks.

### Display parity

Apply the same mode in:

- `Dashboard::QueuePreview` (PR #3065's replay) — in strict mode, skip the round-robin interleaving and present strict priority order.
- `queue_order_display` scope and the "balanced across projects" subtitle added in #3065 (hide/replace the subtitle when not fair-share).

### Worked example

| Run | Project in-flight | Mode | Label |
|-----|-------------------|------|-------|
| P3 in idle project B | 0 | — | — |
| P1 in busy project A | 5 | — | — |

- `fair_share`: B's run dequeues first (0 < 5).
- `strict_priority`: A's P1 dequeues first (P1 < P3).

## Alternatives Considered

### Alternative 1: Per-user setting (revive the removed column, wired up)

**Rejected.** Fairness is a cross-project, cross-user property of the account's project pool. Two members of one account selecting different modes is incoherent — they share one scheduler and one queue view. The original `user_settings.fair_queue_across_projects` was wrong at the scoping layer, which is why removal (not revival) was the short-term fix.

### Alternative 2: Per-project setting

**Rejected.** Fair-share is *defined* across projects; a per-project fairness flag has no coherent meaning (a project cannot be "fair to itself"). Cross-project starvation protection must be decided above the project level.

### Alternative 3: Global reorder with no toggle (priority first, always)

**Rejected.** Removes starvation protection for *every* tenant with no opt-out and no way back. High blast radius for accounts that rely on fair-share (the documented intent in RDR-047 and the `QUEUE_ORDER` comments).

### Alternative 4: Weighted / deficit-round-robin fairness instead of count-based

**Future enhancement, not now.** A weighted fair queue (each project gets a configurable share) is strictly more expressive than the binary toggle, but it adds a per-project weight config surface and a more complex dequeue query. The binary mode resolves the immediate request; weighted fairness can be a follow-up that subsumes `strict_priority` as the "all-equal-weights" degenerate case.

## Trade-offs

### Positive

- Gives accounts an explicit, coherent choice between fairness and strict priority — resolving the gap that the dead setting failed to address.
- Default behavior is unchanged, so existing accounts see no regression.
- Single source of truth (account setting) drives scheduler, Temporal key, and UI consistently.

### Negative

- Ordering scopes must stop being frozen constants and become mode-aware; the mode (or account) must be threaded through dequeue and display call sites. This is the bulk of the implementation cost.
- `strict_priority` reintroduces cross-project starvation for accounts that enable it — acceptable, since they explicitly opted in, but the UI should warn at enable time.

### Risks

- **Two-layer fairness mismatch.** If the Temporal fairness key is not neutralized in strict mode, the SQL ordering may not translate into actual strict dispatch when the worker pool is the bottleneck. Implementation must empirically confirm which layer is binding (see Temporal fairness key above) and add an integration test covering both.
- **Display/scheduler drift.** If the mode is applied in one place but not the other, the upcoming-queue preview lies. Both `Dashboard::QueuePreview` and `queue_order_display` must read the same resolved mode; a shared resolver avoids drift.
- **Migration of mental models.** RDR-047 and the `QUEUE_ORDER` comments currently describe fairness as unconditional; those docs must be updated to "default mode" wording.

## Implementation Plan

### Prerequisite (DONE)

Remove dead `user_settings.fair_queue_across_projects` column (migration `20260729183603`).

### Issue 1: Schema + resolver

- Add `tenant_settings.queue_fairness_mode` column + CHECK constraint.
- Add `TenantSetting#queue_fairness_mode` accessor and a resolver (e.g., `TenantSetting#strict_priority_queue?`) usable from the scheduler and controllers.

### Issue 2: Mode-aware dequeue ordering

- Introduce `AgentRun.queue_order_for(mode:)` returning the key set.
- Thread the resolved mode through `peek_next_queued_run` / `claim_next_queued_run` / `next_queued_run_from` (from `ProcessRunQueueJob`, which has account context).
- Conditionally neutralize `temporal_fairness_key_for` in strict mode; validate the Temporal layer empirically.

### Issue 3: Display parity

- Apply the mode in `queue_order_display` (controller path) and `Dashboard::QueuePreview` (PR #3065).
- Adjust/hide the "balanced across projects" subtitle when not fair-share.

### Issue 4: Settings UI

- Expose the toggle in the account/tenant settings form + strong params + i18n, with a clear warning that strict priority can starve lower-priority work across projects.

### Issue 5: Docs + specs

- Update RDR-047 / `QUEUE_ORDER` comments from "unconditional" to "default mode."
- Specs: dequeue order for both modes; display/scheduler parity under each mode; the worked example above as a regression test.

### Dependency Graph

```
Issue 1 (schema + resolver)
    ├── Issue 2 (dequeue ordering)
    └── Issue 3 (display parity)
Issue 4 (settings UI)        ← depends on Issue 1
Issue 5 (docs + specs)       ← accompanies Issues 2–3
```

## Validation

### Unit Tests

- `queue_order_for(mode:)` returns the expected key sets; strict mode omits the active-count keys.
- Resolver returns `fair_share` by default for accounts with no explicit setting.

### Integration Tests

- Fair-share account: a busy project's P1 does NOT preempt an idle project's P3 (current behavior preserved).
- Strict-priority account: the same P1 DOES dequeue ahead of the P3 (worked example).
- Display/scheduler parity: the `Dashboard::QueuePreview` order matches actual dequeue under both modes.
- Temporal fairness key is constant in strict mode.

### Backward Compatibility

- Migration backfills `fair_share` for all existing rows (column default); no account changes behavior on rollout.

### Monitoring (Post-Rollout)

- Per-account dequeue-order telemetry (mode + resulting starvation metrics) so accounts that enable strict priority can see its effect on cross-project wait times.
