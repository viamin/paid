---
parent: PAID
prefix: INBOX
---

# Low-Level Design: Inbox Foundation

> Companion to the high-level design (`docs/high-level-design.md`). This is the
> foundation LLD for the unified "inbox" UX that surfaces issues and pull
> requests awaiting human input. It introduces two primitives that future inbox
> surfaces (plan review, PR owner approval, paused-run decisions) build on:
>
> 1. A `needs_input_since` timestamp on `Issue` so every inbox entry can answer
>    "how long has this been waiting?"
> 2. A typed `Inbox::Queue` service that returns structured entries —
>    clarifying questions, plan reviews, and merge approvals without UI churn.

The first user of these primitives is the existing
`Dashboard::NeedsInputQueue` (kept as a thin delegator), so the rollout is
behavior-preserving for the current `/dashboard/needs_input` page.

## Purpose

Two trends make the existing single-purpose queue untenable:

- The `needs_input` label now fires from more places as review-gated features
  land (full LID, strict TDD, change-intent records). The queue is busier and
  items wait longer, so operators need to see "waiting 2h" / "waiting 1d" and
  order oldest-first.
- More *kinds* of work now block on human input. Today only "clarifying
  questions" exist; tomorrow adds plan review, PR owner approval, paused-run
  decisions. A single typed abstraction lets a future inbox page render all of
  them without forking the queue service.

This design captures the minimum needed to support both: one timestamp and one
typed queue.

## `needs_input_since` timestamp

A nullable `datetime` on `Issue`. The column is managed by a single model
callback so every transition path converges:

- `paid_state: "new" | "completed" | …` → `"needs_input"`: stamp
  `needs_input_since = Time.current` (preserving an existing value, since the
  issue may already be in needs-input state when an agent re-applies the label).
- `paid_state: "needs_input"` → anything else: clear `needs_input_since = nil`.
- No transition: leave the column alone.

A model callback is preferred over scattered updates because (a) every existing
write path that sets `paid_state: "needs_input"` (`EnhanceIssueActivity`,
`create_agent_run_activity.rb` for RDR-053 create_feature, the no-output
fallback activity, the recheck-signal restoration) then automatically keeps the
timestamp consistent, and (b) the inverse is true of `ClearNeedsInput`: the
"reset to new" branch transitions `paid_state` and clears the timestamp for
free, and only the create_feature resume path (which keeps `paid_state: "needs_input"`)
needs an explicit `needs_input_since: nil` because the issue is no longer
waiting on human input.

Backfill: existing rows in `paid_state: "needs_input"` at deploy time get
`needs_input_since = updated_at` (a fallback for "latest clarifying-questions
comment timestamp" when comment timestamps are not stored locally).

## `Inbox::Queue` service

Generalizes `Dashboard::NeedsInputQueue`. The queue returns typed entries so a
future inbox UI can branch on `entry.kind` instead of duck-typing the issue:

```ruby
Entry = Struct.new(:kind, :project, :issue, :questions, :waiting_since, keyword_init: true)
```

Today three kinds exist:

- `:clarifying_questions` — `issue.paid_state == "needs_input"` and the issue
  has either parsed questions in `body` or a locally-persisted
  `needs_input_questions` (create_feature flow).
- `:plan_review` — an open `DecompositionDecision` pending human review.
- `:merge_approval` — an open PR whose persisted auto-merge blocker snapshot
  shows approval-only failures (`owner_approved` and/or `reviews_fresh`) with
  no other failed or short-circuited blockers. The inbox entry uses the PR's
  approval-wait/head-activity timestamp instead of `needs_input_since`, so PRs
  do not need to enter `paid_state: "needs_input"` just to become visible.

Future kinds (`:paused_run_decision`)
plug in by registering an entry-finder that contributes rows to the same
ordering. The struct shape is fixed so the UI binds to it without churn.

### Visibility and ordering

`Inbox::Queue` keeps the exact scoping semantics of `Dashboard::NeedsInputQueue`:

- Auto-pick projects only, filtered by `Issues::AutoPickProjectGate`.
- Per-owner visibility: the user's own projects plus orphaned-project visibility
  via `AgentRun.orphaned_project_owner?(user)`.
- Optional project filter (the dashboard's `?project_id=`).

Ordering differs in the one way the inbox page cares about:

- **Oldest-waiting-first** by `needs_input_since ASC NULLS LAST`, with a stable
  tiebreak (`projects.owner`, `projects.repo`, `issues.github_number`,
  `issues.id`) so the list is deterministic.

### Including PRs

`Dashboard::NeedsInputQueue` only returns issues (`is_pull_request: false`)
because today's needs-input flow is issues-only. The inbox is broader: the
PR owner-approval and paused-run paths (future kinds) will produce PR entries,
so the queue must include PRs from day one. The SQL therefore drops the
explicit `is_pull_request: false` clause so the inbox is structurally ready.

Current producer state: the consumer side is PR-safe before the producers are.
As of August 26, 2026, the inbox can render and answer a PR-backed
clarifying-question record when that row already contains parseable questions
(`body` marker or persisted `needs_input_questions`), but the shipped producer
flows that populate those questions still target issues: `enhance_issue`,
`create_feature`, and the `FetchIssuesActivity` reconciliation paths are all
issue-scoped today. The missing PR producer remains a follow-up item rather
than a queue/query limitation.

## Delegation from `Dashboard::NeedsInputQueue`

`Dashboard::NeedsInputQueue` keeps its existing public surface
(`.call`, `.next_issue`, `Entry` struct exposing `project`/`issue`/`questions`)
so `/dashboard/needs_input` continues to render unchanged during rollout. Its
implementation delegates to `Inbox::Queue` for the queue body, applies its
own `is_pull_request: false` filter on top, and remaps entries to the legacy
`Entry` shape. The existing spec stays green.

## Future work

This LLD does not introduce additional future inbox kinds beyond the current
set. Further kinds should plug into the same typed queue without rewriting the
inbox surface.
