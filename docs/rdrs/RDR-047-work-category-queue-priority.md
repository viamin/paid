# RDR-047: Work-Category-Aware Queue Priority — PR Continuation Over Fresh Issues

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-07-12
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: P1
- **Related Issues**: TBD (file against this RDR before implementation)
- **Related RDRs**: RDR-031 (Focused Agent Runs — introduced `focus` and `FOCUS_PRIORITY`, orthogonal to this change), RDR-032 (Eager Queue Seeding — removed the PR-attention seeding gate and made `max_concurrent_runs` + `QUEUE_ORDER` the sole capacity/ordering mechanism)

## Implementation Status

Implemented. `AgentRun::QUEUE_PRIORITIES` / `QUEUE_PRIORITY_CASE_SQL` / `queue_priority_tier` now use the 9-tier, category-first scheme described below. Two corrections surfaced during implementation (both incorporated into this doc):

1. `IN_PROGRESS_SQL` was **not** removed — it turned out to still discriminate ties within the `manual` tier (a manual PR-continuation run vs. a manual fresh-issue run), which does not split by category. It is now a no-op for the other 8 tiers only, not all of them. See the corrected Proposed Solution section below.
2. The badge-label call sites that needed updating were not the three originally listed (`tenant_configurations/edit.html.erb`, `accounts/show.html.erb`, `projects/agent_runs_controller.rb` — these reference an unrelated `auto_continue` PR-follow-up toggle setting, not the queue tier). The real call site is `AGENT_RUN_PRIORITY_STYLES` in `app/helpers/application_helper.rb`, which maps `queue_priority_tier` symbols to badge colors and would have silently fallen back to the gray "unknown" style for every non-manual tier under the old key names.

This RDR does not touch capacity gating (`Capacity::RunAdmission`), eager seeding (`Issues::EnqueueEligible`), or focus scoping (RDR-031) — those remain as-is.

## Problem Statement

Operators report that new agent runs keep getting auto-picked and started on **fresh issues** while many existing pull requests carrying the `paid-automation` label sit open with pending work (unresolved review comments, failing CI, merge conflicts) that a follow-up agent run could act on right now.

This is not a missing capacity control (see RDR-032, which deliberately made `max_concurrent_runs` the single concurrency gate and removed the old PR-attention seeding limit by design). It is a **dequeue ordering defect**: `AgentRun::QUEUE_PRIORITY_CASE_SQL` ranks work primarily by *priority label* and only secondarily by *work category* (continuing an existing PR vs. starting a fresh issue). A labeled fresh issue can leapfrog ready, actionable PR-continuation work that carries no label or a lower label, because the label check for `label_p1`/`label_p2` in the SQL `CASE` statement does not condition on whether the run is PR-continuation or fresh-issue work — it fires identically for both.

Concretely, today's tier order (`app/models/agent_run.rb:863-870`, `1052-1073`):

```
0 manual
1 label_p1   (any run — PR or fresh issue — carrying the P1 label)
2 label_p2   (any run — PR or fresh issue — carrying the P2 label)
3 auto_continue  (automatic + existing PR, but ONLY reached if no P1/P2 label matched)
4 label_p3   (any run — PR or fresh issue — carrying the P3 label; only reached if not caught by tier 3)
5 auto_pick  (fresh issue, no label)
```

A P1-labeled fresh issue (tier 1) beats an unlabeled, ready-to-work PR follow-up (tier 3). Worse, a P3-labeled PR follow-up is *also* caught by the tier-3 `auto_continue` branch (since that `WHEN` clause is evaluated before the P3 check), so its label is silently ignored. The net effect: fresh, labeled issue work systematically starves in-flight PR work, and the backlog of open `paid-automation` PRs grows while the queue keeps starting brand-new issues.

Requirements (from stakeholder review):

- The first choice of work should always be the highest-priority **PR continuation** work that is actually workable right now.
- Only when no PR continuation work is workable should the scheduler fall back to the highest-priority **fresh issue**.
- Category beats label rank across categories: a lower-labeled (or unlabeled) PR that is ready to work must be scheduled ahead of a higher-labeled fresh issue that hasn't started. Example given: a P2 PR ready to work beats a P1 issue that has not been auto-picked yet.
- Manual runs always pre-empt every automated decision, unconditionally.
- All of the above operates *inside* existing user-level and tenant-level capacity fairness (`Capacity::RunAdmission`, `max_concurrent_runs`) — this RDR does not change concurrency limits.
- Project-level fairness must be preserved: a single project with a deep backlog of high-priority work must not starve other projects with only lower-priority work, even under the same user/tenant.

## Context

### Current Behavior

- `AgentRun::QUEUE_ORDER` (`app/models/agent_run.rb:1106-1113`) is the dequeue `ORDER BY` used by `ProcessRunQueueJob` via `next_queued_run_from` (`agent_run.rb:1289-1291`) against `schedulable_queued_with_priority` (`agent_run.rb:1280-1287`):

  ```ruby
  QUEUE_ORDER = [
    PROJECT_ACTIVE_COUNT_SQL,   # cross-project fair-share (primary key)
    USER_ACTIVE_COUNT_SQL,      # cross-user fair-share within a project tie
    QUEUE_PRIORITY_SQL,         # the 6-tier CASE described above
    IN_PROGRESS_SQL,            # PR-continuation ahead of fresh work, WITHIN a tier only
    GOAL_PRIORITY_SQL,          # create_issue/enhance_issue/analyze_issue ahead of create_pr
    { created_at: :asc, id: :asc }
  ].freeze
  ```

- `PROJECT_ACTIVE_COUNT_SQL` and `USER_ACTIVE_COUNT_SQL` (`agent_run.rb:1096-1098`) are already the *first* two sort keys, ahead of priority. This is intentional and already delivers the project-level fairness requirement: "a flood of P1s in one project cannot fully starve another project's lower-priority work" (comment at `agent_run.rb:846-848`). **No change needed here** — this RDR preserves both keys in their current position, unchanged.

- `QUEUE_PRIORITY_CASE_SQL` (`agent_run.rb:1052-1073`) is the defect: it interleaves label rank and work category in a single `CASE` in the wrong precedence order (label before category), as detailed in Problem Statement.

- `IN_PROGRESS_SQL` (`agent_run.rb:1080-1083`) was added specifically to sub-sort PR-continuation ahead of fresh work — but only as a tiebreaker *within* an already-matched priority tier (e.g., among two P1-labeled runs). It cannot promote an unlabeled PR run above a labeled fresh-issue run, because tier assignment happens first. Once category becomes the primary axis of `QUEUE_PRIORITY_CASE_SQL` (this proposal), `IN_PROGRESS_SQL` becomes a no-op for 8 of the 9 tiers — every row in a "PR" tier already has `source_pull_request_number IS NOT NULL`, and every row in an "Issue" tier already has it `NULL`. It remains meaningful for exactly one tier: `manual`, which does not split by category (a manual run pre-empts everything regardless of whether it's PR-continuation or fresh-issue work), so two manual runs of different categories still need `IN_PROGRESS_SQL` to break the tie. **Keep it in `QUEUE_ORDER`, scoped in comments to that one remaining case.**

- `GOAL_PRIORITY_SQL` (`agent_run.rb:1084-1090`) ranks `create_issue`/`enhance_issue`/`analyze_issue` goals ahead of `create_pr` within a tier. This is orthogonal to work category (it only meaningfully discriminates within the fresh-issue side, since PR-continuation runs are essentially always `create_pr`) and is preserved unchanged.

### Verified: "workable" filtering already happens upstream

A queued `AgentRun` with `trigger_type: 'automatic'` and `source_pull_request_number` present already only exists when the underlying PR is genuinely actionable:

- **CI-pending PRs never queue a run**: `scan_draft_pr` returns `:skipped` while checks are incomplete (`app/temporal/activities/scan_paid_prs_activity.rb:595-599`); `ci_failure_triggers` only fires on completed, failing conclusions (lines 1556-1557).
- **`draft`/`restarted`/`escalated` PR phases are not blocking** — they're normal working states that legitimately get queued follow-ups (`scan_paid_prs_activity.rb:8-15`; `Automation::Strategies::AutoReview#followup_decisions`, `app/services/automation/strategies/auto_review.rb:289-313`, queues identically for both branches). No gap to close here.
- **Paused PRs are excluded at the scan source**: `find_paid_prs` scopes to `Issue.auto_continue_active` (`scan_paid_prs_activity.rb:309`; `Issue#auto_continue_active` defined `app/models/issue.rb:103` as `where(auto_continue_paused: false)`).
- **Already-active PRs can't double-queue**: `QueueAgentRunActivity#find_existing_run` row-locks and checks for any unfinished run on the issue/PR before creating a new one (`app/temporal/activities/queue_agent_run_activity.rb:49-106, 158-165`).

Conclusion: this RDR does **not** need to add new "is this PR actually workable" filtering. The existing queued-run population is already the correct candidate set; the defect is purely in how that set is *ordered*.

### Technical Environment

- Queue ordering: `AgentRun::QUEUE_ORDER`, `QUEUE_PRIORITY_CASE_SQL`, `QUEUE_PRIORITIES`, `queue_priority_tier` — all in `app/models/agent_run.rb`
- Dequeue: `ProcessRunQueueJob` (`app/jobs/process_run_queue_job.rb`), `AgentRun.next_queued_run` / `next_queued_run_from`
- Badge rendering: `AgentRun#queue_priority_label` and `#queue_priority_tier`, consumed by `AGENT_RUN_PRIORITY_STYLES`/`agent_run_priority_badge` in `app/helpers/application_helper.rb`, rendered from `app/views/projects/_agent_run.html.erb`, `app/views/agent_runs/_index_table.html.erb`, `app/views/agent_runs/_table.html.erb`, `app/views/dashboard/_queue_preview.html.erb`, `app/views/dashboard/_active_run_row.html.erb`
- Label source resolution: `label_priority_tier` / `compute_label_priority_tier` (`agent_run.rb:895-919`), reads `Project::PRIORITY_TIERS` / `Project#priority_label_for`
- Fair stride: `PROJECT_ACTIVE_COUNT_SQL`, `USER_ACTIVE_COUNT_SQL` (RDR-031 / #1274, preserved by RDR-032, preserved unchanged by this RDR)

## Proposed Solution

### Core Idea

Make **work category** (PR continuation vs. fresh issue) the primary discriminator in `QUEUE_PRIORITY_CASE_SQL`, and **priority label** (P1 > P2 > P3 > none) the secondary discriminator *within* each category. Manual pre-emption remains the unconditional top tier. Project/user fair-stride keys remain untouched and continue to sort ahead of all of this.

### New Tier Table

Replace the 6-tier `QUEUE_PRIORITIES` with 9 tiers:

```ruby
QUEUE_PRIORITIES = {
  manual: { label: "Manual", indicator: 1 },
  pr_p1: { label: "PR · P1", indicator: 2 },
  pr_p2: { label: "PR · P2", indicator: 3 },
  pr_p3: { label: "PR · P3", indicator: 4 },
  pr_continue: { label: "Auto-continue", indicator: 5 },
  issue_p1: { label: "P1", indicator: 6 },
  issue_p2: { label: "P2", indicator: 7 },
  issue_p3: { label: "P3", indicator: 8 },
  auto_pick: { label: "Auto-pick", indicator: 9 }
}.freeze
```

### New `QUEUE_PRIORITY_CASE_SQL`

```sql
CASE
  WHEN trigger_type = 'manual' THEN 0
  WHEN source_pull_request_number IS NOT NULL AND EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(issue_labels.labels) AS label(value)
    WHERE LOWER(label.value) = LOWER(COALESCE(NULLIF(p.priority_labels->>'P1', ''), 'P1'))
  ) THEN 1
  WHEN source_pull_request_number IS NOT NULL AND EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(issue_labels.labels) AS label(value)
    WHERE LOWER(label.value) = LOWER(COALESCE(NULLIF(p.priority_labels->>'P2', ''), 'P2'))
  ) THEN 2
  WHEN source_pull_request_number IS NOT NULL AND EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(issue_labels.labels) AS label(value)
    WHERE LOWER(label.value) = LOWER(COALESCE(NULLIF(p.priority_labels->>'P3', ''), 'P3'))
  ) THEN 3
  WHEN source_pull_request_number IS NOT NULL THEN 4
  WHEN EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(issue_labels.labels) AS label(value)
    WHERE LOWER(label.value) = LOWER(COALESCE(NULLIF(p.priority_labels->>'P1', ''), 'P1'))
  ) THEN 5
  WHEN EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(issue_labels.labels) AS label(value)
    WHERE LOWER(label.value) = LOWER(COALESCE(NULLIF(p.priority_labels->>'P2', ''), 'P2'))
  ) THEN 6
  WHEN EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(issue_labels.labels) AS label(value)
    WHERE LOWER(label.value) = LOWER(COALESCE(NULLIF(p.priority_labels->>'P3', ''), 'P3'))
  ) THEN 7
  ELSE 8
END
```

`trigger_type = 'manual'` is checked first and unconditionally wins, so the `source_pull_request_number IS NOT NULL` branches below it never need to re-exclude manual runs — mirrors the existing structure, just reordered.

### New `queue_priority_tier` (Ruby mirror)

```ruby
def queue_priority_tier
  return :manual if manual?

  category = existing_pr? ? "pr" : "issue"
  case label_priority_tier
  when "P1" then :"#{category}_p1"
  when "P2" then :"#{category}_p2"
  when "P3" then :"#{category}_p3"
  else category == "pr" ? :pr_continue : :auto_pick
  end
end
```

### `QUEUE_ORDER` — keep `IN_PROGRESS_SQL`, narrow its documented scope

`IN_PROGRESS_SQL` is *not* dropped: it remains the only tiebreaker between a manual PR-continuation run and a manual fresh-issue run, since the `manual` tier does not split by category (manual pre-emption is unconditional, regardless of work category). For the other 8 tiers it is a true no-op (every row in a "PR" tier already has `source_pull_request_number IS NOT NULL`; every row in an "Issue" tier already has it `NULL`), so its comment is narrowed to document that single remaining case rather than removed:

```ruby
QUEUE_ORDER = [
  PROJECT_ACTIVE_COUNT_SQL,   # unchanged
  USER_ACTIVE_COUNT_SQL,      # unchanged
  QUEUE_PRIORITY_SQL,         # now 9-tier, category-first
  IN_PROGRESS_SQL,            # unchanged; now only breaks ties within the manual tier
  GOAL_PRIORITY_SQL,          # unchanged
  { created_at: :asc, id: :asc }
].freeze
```

`GOAL_PRIORITY_SQL` is unchanged (orthogonal, still discriminates within the issue-side tiers).

### Worked example (validates the stakeholder's tie-break case)

| Run | Category | Label | New tier |
|---|---|---|---|
| P2-labeled, ready PR follow-up | PR | P2 | 3 (`pr_p2`) |
| P1-labeled, not-yet-started fresh issue | Issue | P1 | 5 (`issue_p1`) |

Tier 3 < tier 5, so the P2 PR dequeues first — matching the requirement exactly ("a P2 PR that is ready to be worked on should be worked before a P1 issue that has not been started").

### Project-level and manual-preemption behavior — unchanged, verified preserved

- `PROJECT_ACTIVE_COUNT_SQL` / `USER_ACTIVE_COUNT_SQL` remain the first two `QUEUE_ORDER` keys, so no change to cross-project or cross-user fairness. A project with many P1 PRs still only jumps ahead of another project at equal in-flight-count ties, exactly as today.
- `trigger_type = 'manual'` remains tier 0 unconditionally, independent of category or label — manual pre-emption is untouched.

## Alternatives Considered

### Alternative 1: Keep a single flat priority number, just reorder the `WHEN` clauses

Simply move the `automatic AND source_pull_request_number IS NOT NULL` check above the label checks, collapsing PR and label into fewer tiers (e.g., "any PR beats any label"). **Rejected** because it loses label ordering *within* the PR category — a P3-labeled PR and an unlabeled PR would be indistinguishable, and a human-set P1 label on a PR should still be able to jump ahead of a P1-labeled PR in a different tie... actually this alternative can't express "PR P1 vs PR P2" ordering at all without the same two-dimensional structure this RDR proposes. Effectively collapses to the same design; called out separately only to confirm it doesn't save complexity.

### Alternative 2: Two independent sort columns (category, then label) instead of one combined `CASE`

Add `WORK_CATEGORY_SQL` (`0` = PR, `1` = issue) and keep a separate label-rank SQL, inserting both into `QUEUE_ORDER` as two keys instead of one combined tier. **Rejected**: functionally equivalent ordering, but `queue_priority_label` (the UI badge) needs one enumerable value per run for rendering ("PR · P1", "Auto-pick", etc.) — a single combined tier keeps the existing `QUEUE_PRIORITIES` hash / badge-rendering contract intact and avoids a second migration of every call site that reads `queue_priority_tier`/`queue_priority_label`.

### Alternative 3: Add an explicit "workability" filter to the ordering (CI status, phase, pause) instead of trusting upstream gating

**Rejected** — investigation confirmed (see Context, "Verified: workable filtering already happens upstream") that `ScanPaidPrsActivity`, `Issue.auto_continue_active`, and `QueueAgentRunActivity#find_existing_run` already ensure a queued PR-continuation run only exists when the PR is actionable. Duplicating that logic in the ordering layer would be redundant and risks the two implementations drifting.

### Alternative 4: Revert to RDR-032's predecessor (seeding-time PR attention limit)

Bring back `deferred_by_pr_attention_limit?`/`max_auto_pick_open_prs` as a seeding-time gate instead of fixing dequeue ordering. **Rejected** — this was explicitly removed by RDR-032 to fix a *different*, real problem (empty dashboard queue preview, tick-based staleness) and reintroducing it would regress that fix. It also doesn't address the actual defect: even with a PR-attention limit, labeled fresh issues would still leapfrog PR work whenever the limit wasn't yet hit.

## Trade-offs

### Positive

- Fixes the reported defect: ready PR-continuation work is no longer starved by fresh, labeled issues.
- Directly implements all five stakeholder requirements (PR-first, fallback to issues, cross-category tie-break example, manual pre-emption, project/user fairness) with no change to capacity gating or eager seeding.
- No schema/migration required — pure `AgentRun` constant and SQL change.

### Negative

- Badge labels change (6 → 9 tiers; "P1"/"P2"/"P3" badges now read "PR · P1"/"PR · P2"/"PR · P3" for PR-continuation runs vs plain "P1"/"P2"/"P3" for fresh-issue runs). `AGENT_RUN_PRIORITY_STYLES` in `app/helpers/application_helper.rb` needs its keys renamed to match (done as part of this change) or every non-manual badge silently falls back to the gray "unknown" style.
- A project whose entire backlog is fresh issues (no in-flight PRs at all) sees no ordering change — this only matters for projects with a mix of PR-continuation and fresh-issue queued work, which is expected to be the common case where the bug manifests.
- Operators who had mentally modeled the tier list as "priority label first" will need to update that model to "category first, then label."

### Risks

- **Existing specs assert the old tier numbers/labels.** `spec/models/agent_run_spec.rb`, `spec/requests/agent_runs_spec.rb`, and `spec/jobs/process_run_queue_job_spec.rb` reference `QUEUE_PRIORITIES`, `queue_priority_tier`, `auto_continue`, `label_p1`/`label_p2`/`label_p3`, and ordering assumptions built on the 6-tier scheme. All three need updates as part of implementation, not as an afterthought.
- **Silent badge-string dependents.** If any code outside the three known call sites string-matches `queue_priority_label` output (e.g., a saved Slack/webhook template), it would break silently. Grep before merge to confirm no other consumers.

## Implementation Plan

### Issue 1: Core ordering change

- Update `QUEUE_PRIORITIES` (9 tiers), `QUEUE_PRIORITY_CASE_SQL`, `queue_priority_tier` in `app/models/agent_run.rb`
- Keep `IN_PROGRESS_CASE_SQL`/`IN_PROGRESS_SQL` in `QUEUE_ORDER`, narrowing the comment to note it now only discriminates within the `manual` tier
- Unit tests: every category × label combination (`pr_p1` through `auto_pick`) resolves to the correct tier; manual always wins regardless of category/label; the P2-PR-vs-P1-issue worked example from this RDR as an explicit regression test

### Issue 2: Badge/UI updates

- Rename the keys in `AGENT_RUN_PRIORITY_STYLES` (`app/helpers/application_helper.rb`) from the old 6-tier names (`label_p1`, `auto_continue`, `label_p3`, ...) to the new 9-tier names (`pr_p1`, `pr_p2`, `pr_p3`, `pr_continue`, `issue_p1`, `issue_p2`, `issue_p3`, `auto_pick`), so `agent_run_priority_badge` doesn't silently fall back to the gray "unknown" style
- Confirm no other consumer string-matches the old labels (grep sweep)

### Issue 3: Spec updates

- `spec/models/agent_run_spec.rb`: replace 6-tier assertions with 9-tier assertions
- `spec/requests/agent_runs_spec.rb`, `spec/jobs/process_run_queue_job_spec.rb`: update any fixture/ordering expectations built on old tier numbers
- Add an integration test at the `ProcessRunQueueJob` level: given one project with a P1 fresh issue queued and a P3-labeled PR-continuation run queued, assert the PR-continuation run dequeues first

### Dependency Graph

```
Issue 1 (core ordering change)
    ├── Issue 2 (badge/UI updates)
    └── Issue 3 (spec updates)
```

## Validation

### Unit Tests

- `queue_priority_tier` for all 9 combinations (manual; PR × {P1,P2,P3,none}; issue × {P1,P2,P3,none})
- `QUEUE_PRIORITY_SQL` produces the same tier ordering as the Ruby mirror for a seeded set of runs (parity test, mirroring any existing SQL/Ruby parity spec pattern already in `agent_run_spec.rb`)

### Integration Tests

- Dequeue order across a mixed queue: manual > PR-P1 > PR-P2 > PR-P3 > PR-unlabeled > issue-P1 > issue-P2 > issue-P3 > issue-unlabeled
- Cross-category tie-break: P2 PR dequeues before P1 issue (this RDR's motivating example)
- Project fair-stride unchanged: two projects with mixed PR/issue queues still alternate by `PROJECT_ACTIVE_COUNT_SQL`, unaffected by the tier redefinition
- Manual pre-emption unchanged: a manual run dequeues ahead of any PR-P1 automated run

### Backward Compatibility / Regression

- Re-run existing `process_run_queue_job_spec.rb` scenarios with updated tier expectations to confirm no unrelated ordering regressions (e.g., `create_issue`-ahead-of-`create_pr` via `GOAL_PRIORITY_SQL` still holds)

### Monitoring (Post-Rollout)

- Track open `paid-automation` PR count over time per project — should trend down/stabilize instead of growing unbounded once PR-continuation work is reliably prioritized over fresh auto-pick
- Track time-in-queue for PR-continuation runs vs. fresh-issue runs, confirming the former's median wait drops
