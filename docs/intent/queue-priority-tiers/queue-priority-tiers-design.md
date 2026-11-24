---
parent: PAID
prefix: QUEUE-TIER
---

# Low-Level Design: Queue Priority Tiers

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the work-category-aware dequeue ordering of queued runs
> (RDR-047): how `AgentRun::QUEUE_PRIORITY_CASE_SQL` and its Ruby mirror
> rank runs. The sibling `account-queue-fairness` segment covers the
> account-level choice between fair-share and strict-priority *modes*;
> `eager-queue-seeding` covers how runs enter the queue.

## Purpose

Operators saw fresh, labeled issues getting started while ready, actionable
PR-continuation work (unresolved reviews, failing CI, merge conflicts on
open `paid-automation` PRs) sat idle. The defect was dequeue ordering: the
priority `CASE` ranked work by *label* first and *work category* second, so
a P1-labeled fresh issue leapt ahead of an unlabeled but ready PR follow-up.
Making **work category** (PR continuation vs. fresh issue) the primary
discriminator and **label** the secondary one fixes that without touching
capacity gating.

## The 10-tier, category-first scheme

`AgentRun::QUEUE_PRIORITIES` defines ten tiers, evaluated in this order by
`QUEUE_PRIORITY_CASE_SQL`:

| Tier | Indicator | When |
|---|---|---|
| `manual` | 1 | Manual launch or an explicitly requested operator priority for a queued acceptance audit |
| `operator_coding` | 2 | Explicitly prioritized existing automatic coding retry |
| `pr_p1` | 3 | PR-continuation run carrying the configured P1 label |
| `pr_p2` | 4 | PR-continuation run carrying the configured P2 label |
| `pr_p3` | 5 | PR-continuation run carrying the configured P3 label |
| `pr_continue` | 6 | PR-continuation run with no priority label |
| `issue_p1` | 7 | Fresh-issue run carrying the configured P1 label |
| `issue_p2` | 8 | Fresh-issue run carrying the configured P2 label |
| `issue_p3` | 9 | Fresh-issue run carrying the configured P3 label |
| `auto_pick` | 10 | Fresh-issue run with no priority label |

A run is PR-continuation when `source_pull_request_number IS NOT NULL`, and
fresh-issue otherwise. Label matching is case-insensitive and reads the
project's configured priority labels (`Project::PRIORITY_TIERS`); the
label-rank `CASE` (`LABEL_RANK_CASE_SQL`) is defined once and interpolated
into both category branches so PR and issue sides rank labels identically.

The defining worked example: a P2-labeled, ready PR follow-up (tier `pr_p2`,
indicator 4) dequeues ahead of a P1-labeled, not-yet-started fresh issue
(tier `issue_p1`, indicator 7), because category beats label *across*
categories.

### Explicit operator coding-retry requests

An authorized operator may prioritize one existing, unclaimed automatic
`create_pr` retry through `AgentRuns::PrioritizeCodingRetry`. The service locks
and rechecks the selected row, records `operator_coding_priority_requested_at`
and one actor audit event, then wakes the scheduler. The request is available
from the queued PR action and the confirmation-gated MCP tool; sweeps, issue
text, comments, and automatic retry code cannot set it.

Only automatic coding work that is a PR continuation, an implementation
continuation request, or a bounded root retry evidenced by retained issue
attempt history is eligible. Root evidence includes either a positive automatic
failure streak or a preceding same-issue manual timeout; the latter recognizes
an already-queued automatic root without fabricating automatic failure,
continuation, or source-PR lineage. Manual, audit-only,
untrusted-originated, claimed, running, terminal, and rate-limited work is
refused. Repeated and concurrent requests converge on the first timestamp and
audit event. The marker ranks after manual and operator-prioritized audit work
and before ordinary PR-continuation and fresh-issue tiers. Project/user
fair-share keys remain earlier scheduler sort keys, so the request advances
the retry only inside its existing fairness cohort.

The marker is scheduling state only. It never creates, cancels, restarts, or
claims a run and never changes trigger, execution origin, runner/model/privacy
or billing policy, admission evidence, retry metadata, continuation/source
identity, backoff, or retry allowance. It is intentionally durable rather than
silently expiring or clearing: revocation/expiration, if introduced, must add
an audit record and cannot erase lineage or reset retry state. Dequeue retains
all ordinary authorization, trust, dependency, phase, pause, cost, capacity,
and finite-retry checks.

## Ruby mirror and badges

### Explicit operator acceptance requests

An operator joining an existing automatic acceptance audit requests its place in
the operator tier through `AgentRuns::PrioritizeAudit`. The service authorizes
the actor, locks the run, and records `operator_priority_requested_at` only for
an unclaimed queued report-only audit. It records the actor and original
request/run identity through the account activity audit. Repeated requests keep
the first timestamp and audit event. Automatic joins do not request priority.

The timestamp is scheduling state. The original trigger, continuation evidence,
policy signature, runner and retry lineage retain their original values, and
dequeue still applies automatic authorization, trust, pause, budget and capacity
checks. Claimed, running, terminal and implementation work keep their current
ordering. The badge identifies an operator-requested audit while its trigger
remains automatic. Cross-project and cross-user fairness retain precedence.

| Decision | Rationale | Alternatives considered |
| --- | --- | --- |
| Store one timestamp on the existing run and use the existing actor audit. | Queue SQL and badges can read the request without another identity or admission. | Rewriting the trigger would change authority; recreating the run would discard identity/lineage; changing concurrency would alter capacity policy. |

`AgentRun#queue_priority_tier` mirrors the SQL for rendering: manual and
operator-requested audits win unconditionally; an operator-requested coding
retry precedes ordinary automatic PR continuations and fresh issues; then the
run's category (`existing_pr?` → `pr` else `issue`) is combined with
`label_priority_tier` to pick `pr_p1`..`pr_p3` / `pr_continue` or
`issue_p1`..`issue_p3` / `auto_pick`. `queue_priority_label`
maps the tier to the badge string ("PR · P1", "Auto-pick", …), and
`AGENT_RUN_PRIORITY_STYLES` in the application helper maps each tier key to a
badge color so no tier silently falls back to the gray "unknown" style.

## Position in `QUEUE_ORDER`

`QUEUE_ORDER` (and the scheduler variant) keeps its structure — the category
tier is only the **third** sort key:

```
project_active_count   → cross-project fair-share (primary)
user_active_count      → cross-user fairness within a project tie
queue_priority         → the 10-tier category-first CASE (this segment)
in_progress            → tie-break WITHIN the manual tier only
goal_priority          → create_issue/enhance_issue/analyze_issue ahead of create_pr
created_at, id         → FIFO tiebreaker
```

Because the project/user fair-stride keys stay first, a single project's
deep backlog of high-priority work cannot starve other projects. The
`in_progress` tiebreak is now a true no-op for the nine non-manual tiers
(every PR tier fixes `source_pull_request_number` NOT NULL, every issue tier
fixes it NULL) and only discriminates a manual PR-continuation run from a
manual fresh-issue run; it is retained, scoped in comments to that one case.

## Workability filtering happens upstream

This ordering does not re-check whether a PR is actually workable. That is
already guaranteed before a queued run exists: CI-pending PRs never queue a
run; operator-paused PRs are excluded at the scan source
(`Issue.auto_continue_active`); escalated PRs stay in the scan but the scan
decides no work for them (see `pr-escalation-recovery`); and
`QueueAgentRunActivity#find_existing_run` row-locks so an active PR cannot
double-queue. The ordering layer trusts that candidate set.

## What this is not

- **Not a capacity change.** This redefines ordering only; it does not touch
  `max_concurrent_runs` or `Capacity::RunAdmission`.
- **Not a fairness-mode switch.** Whether the project/user active-count keys
  are applied at all (fair-share vs. strict-priority) is the
  `account-queue-fairness` concern; the tier *definition* is shared by both.
- **Not seeding or focus logic.** Seeding is `eager-queue-seeding`; run
  scoping is `focused-agent-runs`.
