# RDR-032: Eager Queue Seeding — Eliminate Auto-Pick Throttling

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-05-15
- **Status**: Draft
- **Type**: Architecture
- **Priority**: P1
- **Related Issues**: #2019 (foundation), #2020 (sync hooks), #2021 (remove throttling), #2022 (dependency resolution)
- **Related RDRs**: RDR-023 (Automation Modularization), RDR-031 (Focused Agent Runs)

## Problem Statement

The dashboard queue preview is empty even when many eligible issues are ready for work. This happens because auto-pick seeds runs conservatively — one per project per tick, gated by a PR attention limit — rather than eagerly queueing all eligible issues and letting the scheduler decide what to start.

The current throttling model has three layers of indirection between "an issue exists and is eligible" and "it appears in the queue":

1. **One-run-per-project-per-tick seeding** — `seed_auto_pick_queue` creates at most one queued `AgentRun` per project per `ProcessRunQueueJob` invocation, then loops round-robin. A project with 20 eligible issues only ever has 1 run in the queue at a time.
2. **PR attention limit** — `deferred_by_pr_attention_limit?` blocks ALL new auto-pick runs for a project when its open PRs needing attention reach `max_auto_pick_open_prs`. With the default of 4, a project with 4 in-progress PRs cannot queue new work even though `max_concurrent_runs` may allow it.
3. **Tick-based scheduling** — `ProcessRunQueueJob` runs every 5 minutes (or reactively on completion events). Between ticks, the queue is stale.

The user-visible symptom: the "Upcoming Queue" on the dashboard shows nothing, even though issues are ready. The operator must mentally track what should be queued next rather than seeing the full backlog at a glance.

Requirements:

- All eligible issues should be queued immediately when they become eligible (on sync, on auto-pick enable, on dependency resolution)
- The queue preview should show the full upcoming backlog, not just runs that happened to be seeded this tick
- `max_concurrent_runs` (per-user, with tenant guardrail) controls how many runs start concurrently — it should be the single capacity gate
- Fair stride across projects (RDR-031 / #1274) must be preserved — queuing all issues must not starve other projects
- No bulk SQL upsert — use Rails `find_or_create_by!` for correctness over throughput

## Context

### Current Behavior

Issue-to-queue flow (current):

1. `FetchIssuesActivity` syncs issues from GitHub → `Issues::UpsertFromGithub`
2. `DetectLabelsActivity` evaluates labels and may transition `paid_state`
3. `ProcessRunQueueJob#seed_auto_pick_queue` runs (cron every 5 min, or reactive)
4. For each eligible project (sorted by fewest active runs), `Issues::AutoPick`:
   a. Checks PR attention limit (`prs_needing_attention_count >= max_auto_pick_open_prs`) — if hit, noop
   b. Runs `DefaultCandidateSource#next_candidate` to find ONE eligible issue
   c. Resolves a provider via `AgentRuns::ProviderResolver`
   d. Creates a single queued `AgentRun` with `trigger_type: "automatic", auto_pick: true`
5. `ProcessRunQueueJob` dequeue loop starts queued runs up to `max_concurrent_runs`
6. `Dashboard::QueuePreview` shows already-queued runs, filtered by user's visible projects

### Eligibility Rules (Preserved)

The `DefaultCandidateSource` eligibility criteria remain unchanged:

- `Issue.ready_for_work(project)` — no open/blocking dependencies
- No active/queued/paused `AgentRun` already attached (`idx_agent_runs_unique_active_issue`)
- Not a parent of an open PR
- `paid_state` in `%w[new planning failed]` or recoverable completed
- Source is `github` or `synthetic_code_scanning`
- Creator in `allowed_github_usernames` if configured
- Labels exclude `planning`, `research`, `waiting`, `tracking`, `epic`, `needs-manual-setup`
- No open non-PR sub-issues blocking the parent
- Tracker/meta issues blocked while body references are open

### Technical Environment

- Issue sync: `FetchIssuesActivity` → `Issues::UpsertFromGithub` (per-issue `find_or_initialize_by`)
- Auto-pick strategy: `Automation::Strategies::AutoPick` + `DefaultCandidateSource`
- Queue processing: `ProcessRunQueueJob` with advisory lock
- Queue ordering: `AgentRun::QUEUE_ORDER` (6-tier priority + fair stride + FIFO)
- Capacity: `max_concurrent_runs` (user setting, capped by `TenantSetting#max_concurrent_runs`)
- Fair stride: `PROJECT_ACTIVE_COUNT_SQL` in `QUEUE_ORDER` (RDR-031 / #1274)

## Proposed Solution

### Core Idea

Replace tick-based one-at-a-time seeding with **eager seeding**: create a queued `AgentRun` for every eligible issue immediately when it becomes eligible. Let the scheduler (`QUEUE_ORDER` + `max_concurrent_runs` + fair stride) decide which runs to start, rather than having the seeding layer make capacity decisions.

### Design Decisions

1. **Seed on sync, not on tick** — When `FetchIssuesActivity` creates or updates an issue, check eligibility and create a queued run immediately. No need to wait for `ProcessRunQueueJob`'s next tick.

2. **Remove PR attention limit** — `max_auto_pick_open_prs` is eliminated as a seeding gate. `max_concurrent_runs` is the single capacity control. If 10 PRs need attention but capacity is 3, only 3 runs start — the other 7 wait in the queue, visible in the dashboard preview.

3. **Use `find_or_create_by!`** — No bulk upsert. The unique index `idx_agent_runs_unique_active_issue` prevents duplicates. On race, `RecordNotUnique` is caught and the existing run is used (same as current `Issues::AutoPick` behavior).

4. **Preserve fair stride** — `QUEUE_ORDER` already includes `PROJECT_ACTIVE_COUNT_SQL` for cross-project fair-share. Eager seeding adds more queued runs per project but does not change which runs the scheduler starts. A project with 20 queued issues still only gets its fair share of concurrent slots.

5. **Bulk seeding only on import and enable** — When a project is first imported or when `auto_pick_enabled` is toggled on, seed all currently-eligible issues at once. During steady-state sync, individual issues are seeded one-at-a-time as they arrive.

### Architecture Changes

#### 1. New Service: `Issues::EnqueueEligible`

A thin service that checks a single issue against `DefaultCandidateSource` eligibility rules and creates a queued `AgentRun` if it passes:

```ruby
module Issues
  class EnqueueEligible
    def initialize(issue, project:)
      @issue = issue
      @project = project
    end

    def call
      return nil unless eligible?
      return nil unless provider_resolved?

      AgentRun.find_or_create_by!(
        project: @project,
        issue: @issue,
        status: AgentRun::AUTO_PICK_BLOCKING_STATUSES
      ) do |run|
        run.assign_attributes(
          provider: provider,
          agent_type: Provider.agent_type_for(provider.provider_key),
          status: "queued",
          trigger_type: "automatic",
          auto_pick: true,
          goal: goal
        )
      end
    rescue ActiveRecord::RecordNotUnique
      AgentRun.find_by(
        project: @project,
        issue: @issue,
        status: AgentRun::AUTO_PICK_BLOCKING_STATUSES
      )
    end
  end
end
```

This replaces `Issues::AutoPick` as the single-issue seeding path. It does NOT check PR attention limits or per-project active run counts — those are scheduling concerns handled by `ProcessRunQueueJob` and `QUEUE_ORDER`.

#### 2. Hook into Issue Sync

After `Issues::UpsertFromGithub` creates/updates an issue, call `EnqueueEligible` if the project has auto-pick enabled:

```ruby
# In FetchIssuesActivity or a new after-sync callback:
if project.auto_pick_enabled? && issue.github_state == "open" && !issue.is_pull_request?
  Issues::EnqueueEligible.new(issue, project: project).call
end
```

This runs per-issue during the sync batch, so no separate tick is needed.

#### 3. Bulk Seeding on Import / Enable

Two trigger points for bulk seeding:

**a. Project import** — After `Projects::Import` completes its initial issue sync, call:

```ruby
Issues::BulkEnqueueEligible.call(project: project)
```

**b. `auto_pick_enabled` toggle** — Replace the existing `trigger_auto_pick` callback (which fires `ProcessRunQueueJob`) with direct bulk seeding:

```ruby
after_update_commit :seed_eligible_issues, if: :auto_pick_just_enabled?

def seed_eligible_issues
  Issues::BulkEnqueueEligible.call(project: self)
rescue => e
  Rails.logger.error(message: "auto_pick.bulk_seed_failed", project_id: id, error: e.message)
end
```

`BulkEnqueueEligible` iterates `DefaultCandidateSource.eligible_scope(project)` and calls `EnqueueEligible` per issue:

```ruby
module Issues
  class BulkEnqueueEligible
    def self.call(project:)
      return unless project.auto_pick_enabled?

      source = Automation::Strategies::AutoPick::DefaultCandidateSource
      source.eligible_scope(project).find_each do |issue|
        EnqueueEligible.new(issue, project: project).call
      end
    end
  end
end
```

Uses `find_each` (batched loading) + `find_or_create_by!` per issue. No bulk SQL.

#### 4. Remove `seed_auto_pick_queue` from `ProcessRunQueueJob`

The `seed_auto_pick_queue` method and its helper `ordered_auto_pick_projects` are removed. `ProcessRunQueueJob` retains only the dequeue loop (claim queued runs and start them up to `max_concurrent_runs`).

The job is still triggered reactively when runs complete, but it no longer seeds — it only starts.

#### 5. Remove PR Attention Limit

- Remove `max_auto_pick_open_prs` from `UserSetting` (or deprecate the column without removing it yet)
- Remove `prs_needing_attention_count`, `max_auto_pick_open_prs`, and `deferred_by_pr_attention_limit?` from `Automation::Strategies::AutoPick` and `Issues::AutoPick`
- Remove `PR_ATTENTION_COUNT_KEY` and `PR_ATTENTION_LIMIT_KEY` constants
- Remove `build_context` PR-attention metadata assembly from `Issues::AutoPick`

The strategy's `evaluate` method simplifies to:

```ruby
def evaluate(context)
  project = context.project
  return noop_result unless auto_pick_enabled?(project)
  return noop_result if project.quality_paused?

  issue = @candidate_source.next_candidate(project)
  return noop_result unless issue

  decision = ...
end
```

#### 6. Dashboard Queue Preview — No Changes Needed

`Dashboard::QueuePreview` already queries `AgentRun.schedulable_queued_with_priority` ordered by `QUEUE_ORDER`. With eager seeding, queued runs now represent the full backlog of eligible issues, so the preview naturally shows all upcoming work. No code changes needed.

### Dependency Resolution Edge Case

When a blocking issue is closed and its dependent becomes unblocked, the dependent is not automatically re-synced by `FetchIssuesActivity` (which only syncs from GitHub). Two options:

1. **Re-evaluate on dependency close** — Add a callback when an issue transitions to `closed` that re-checks dependents and enqueues any newly-eligible ones.
2. **Rely on next sync tick** — The next `FetchIssuesActivity` cycle will re-evaluate the dependent issue and enqueue it.

Option 1 is preferred for responsiveness. A lightweight `after_update_commit` on `Issue` (when `github_state` changes to `closed`) can trigger `EnqueueEligible` for each dependent.

### Fair Stride Impact

None. `QUEUE_ORDER` already includes:

```
PROJECT_ACTIVE_COUNT_SQL  →  fewest active runs per project first
USER_ACTIVE_COUNT_SQL     →  cross-user fairness within project tie
QUEUE_PRIORITY_SQL        →  6-tier priority
```

Eager seeding adds more rows to the queue per project but does not change the dequeue order. A project with 50 queued runs still only gets capacity when the stride calculation gives it a turn. The dashboard preview shows the full queue (useful for visibility) while the scheduler only starts what capacity allows.

## Implementation Plan

### Issue 1: Foundation — `EnqueueEligible` + `BulkEnqueueEligible` services

- Create `Issues::EnqueueEligible` service
- Create `Issues::BulkEnqueueEligible` service
- Both use `find_or_create_by!` with `RecordNotUnique` rescue
- Unit tests for eligible/ineligible issues, duplicate handling, provider resolution

### Issue 2: Hook into sync — Seed on issue upsert

- Modify `FetchIssuesActivity` (or add callback in `Issues::UpsertFromGithub`) to call `EnqueueEligible` after upsert when `auto_pick_enabled`
- Modify `Projects::Import` to call `BulkEnqueueEligible` after initial sync
- Replace `Project#trigger_auto_pick` callback with `seed_eligible_issues` using `BulkEnqueueEligible`
- Integration tests: issue synced → run queued; import → all eligible issues queued; toggle → bulk enqueue

Depends on: Issue 1.

### Issue 3: Remove throttling — Delete `seed_auto_pick_queue` and PR attention limit

- Remove `ProcessRunQueueJob#seed_auto_pick_queue` and `ordered_auto_pick_projects`
- Remove PR attention limit from `Automation::Strategies::AutoPick` and `Issues::AutoPick`
- Remove or deprecate `max_auto_pick_open_prs` from `UserSetting`
- Remove `PR_ATTENTION_COUNT_KEY`, `PR_ATTENTION_LIMIT_KEY` constants
- Update `ProcessRunQueueJob#perform` to only dequeue (no seeding)
- Update tests

Depends on: Issue 2 (so seeding has a new home before removing the old one).

### Issue 4: Dependency resolution — Re-evaluate on dependency close

- Add `after_update_commit` on `Issue` to enqueue newly-unblocked dependents when a blocker closes
- Uses `EnqueueEligible` per dependent
- Edge case: transitive dependencies (A blocks B blocks C) — closing A should enqueue B, and B being picked up eventually leads to C being eligible. This happens naturally if B's completion triggers re-evaluation.

Depends on: Issue 1.

### Dependency Graph

```
Issue 1 (foundation: EnqueueEligible + BulkEnqueueEligible)
    ├── Issue 2 (hook into sync + import + toggle)
    │       └── Issue 3 (remove throttling)
    └── Issue 4 (dependency resolution)
```

## Alternatives Considered

### Alternative 1: Keep one-at-a-time seeding, just remove PR attention limit

Remove the PR attention guard but keep the one-run-per-project-per-tick seeding. This would partially fix the empty queue but still require multiple ticks to fill it. **Rejected** because the dashboard still wouldn't show the full backlog, and the tick-based approach is unnecessarily conservative.

### Alternative 2: Keep `seed_auto_pick_queue` but remove the per-project limit

Let `seed_auto_pick_queue` create multiple runs per project in a single pass (remove the "one per project" round-robin). **Rejected** because it's a half-measure — the seeding still happens on a tick schedule rather than reactively on sync, and it keeps complexity in `ProcessRunQueueJob` that belongs closer to the issue lifecycle.

### Alternative 3: Query issues directly in `Dashboard::QueuePreview` instead of creating runs

Change the queue preview to show eligible issues directly rather than queued `AgentRun` records. **Rejected** because:

- Eligibility is expensive to compute per-request (complex SQL with dependency checks, label exclusions, sub-issue checks)
- Issues don't have a provider assigned until they become runs
- The queue would need to duplicate priority/stride logic already in `QUEUE_ORDER`
- Having a real queued run is useful for tracking (when was it queued, how long has it waited, etc.)

### Alternative 4: Bulk upsert for performance

Use `INSERT ... ON CONFLICT DO NOTHING` for bulk seeding. **Rejected** per design decision — correctness and auditability over throughput. Bulk seeding only happens on import and enable, not on every sync, so the performance hit of `find_or_create_by!` is acceptable.

## Trade-offs

### Positive

- **Dashboard shows full backlog** — Every eligible issue appears in the queue preview, giving operators a complete picture of upcoming work
- **Single capacity gate** — `max_concurrent_runs` controls concurrency; no need for separate PR attention limits
- **Faster pickup** — Issues are queued immediately on sync, not after waiting for the next `ProcessRunQueueJob` tick
- **Simpler mental model** — "Eligible issue → queued run → scheduler starts it" replaces the multi-layer throttling
- **Fair stride preserved** — No change to dequeue ordering; projects still get fair capacity share
- **Reactive, not tick-based** — Seeding happens on issue lifecycle events, not on cron

### Negative

- **More queued `AgentRun` rows** — A project with 50 eligible issues now has 50 queued runs instead of 1. This increases table size but has minimal query impact since `schedulable_queued_with_priority` is indexed.
- **Provider resolution per issue at seed time** — Currently, the provider is only resolved when the run is about to be seeded (one at a time). With eager seeding, the provider is resolved for all eligible issues upfront. If a provider is added or removed later, queued runs may reference a stale provider. Mitigation: `ProcessRunQueueJob` can re-resolve the provider at dequeue time (or skip runs with invalid providers).
- **Bulk seeding on import may be slow** — For a project with hundreds of issues, `find_or_create_by!` per issue is slower than bulk SQL. Acceptable because it only happens once (on import or toggle).
- **`max_auto_pick_open_prs` removal** — Users who relied on this setting to limit PR WIP will need to use `max_concurrent_runs` instead, which is a coarser control (it limits all concurrent runs, not just PR-related ones).

### Risks

- **Queue depth explosion** — If many projects have many eligible issues, the queue grows large. Mitigated by `schedulable_queued_with_priority` scope filtering out paused/scheduler-paused projects, and by `Dashboard::QueuePreview` limiting display to 20 entries.
- **Stale queued runs** — An issue may be queued, then its labels change on GitHub to include `planning` or `waiting`. The queued run still exists. Mitigation: `DefaultCandidateSource` already excludes issues with existing active runs, so a new run won't be created. The stale queued run will eventually be dequeued; `ProcessRunQueueJob` should check eligibility at dequeue time and skip runs for issues that are no longer eligible.
- **Provider exhaustion** — If the provider is rate-limited, having many queued runs doesn't help throughput. Mitigation: this is already the case today — `max_concurrent_runs` limits actual concurrent execution regardless of queue depth.

## Validation

### Unit Tests

- `EnqueueEligible`: eligible issue → queued run created; ineligible issue → nil; duplicate → existing run returned; no provider → nil
- `BulkEnqueueEligible`: project with 10 eligible issues → 10 queued runs; project with auto_pick disabled → no-op
- Eligibility rules preserved: excluded labels, blocking deps, wrong paid_state, existing active run

### Integration Tests

- Sync new issue → run queued immediately (no tick wait)
- Import project → all eligible issues queued
- Toggle `auto_pick_enabled` on → bulk enqueue fires
- Toggle off → queued automatic runs remain but no new seeding
- Dependency closed → dependent issue enqueued

### Queue Ordering Tests

- Fair stride unchanged: two projects with queued runs still alternate dequeue
- Priority tiers unchanged: P1 manual run dequeues before P2 auto-pick
- `max_concurrent_runs` respected: only N runs start concurrently regardless of queue depth

### Dashboard Tests

- Queue preview shows queued runs for user's projects
- Queue preview reflects newly-seeded issues after cache TTL (10s)

### Migration / Backward Compatibility Tests

- Existing queued auto-pick runs continue to be processed
- `ProcessRunQueueJob` dequeue loop works with both old and new queued runs
- `max_auto_pick_open_prs` column presence does not cause errors (soft deprecate)
