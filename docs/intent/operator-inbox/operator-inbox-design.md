# Design: Operator Inbox

## Planned exploration entry

[RDR-069](../../rdrs/RDR-069-question-centered-chat-exploration.md) adds an
opt-in entry from clarifying questions to persistent contextual chat. The
[question-exploration segment](../question-exploration/question-exploration-design.md)
owns conversation, diagram and partial-answer behavior. Existing Inbox
actions remain in this segment; opening chat or commenting on a diagram does
not resolve an Inbox item. Approval-specific feature entries apply to the
approval-gated policy; confidence-driven entries explain issue readiness and
completion dependencies under RDR-071 instead of requesting Mark approved.

> Segment: operator-inbox · Status: implemented
> Specs: [operator-inbox-specs.md](operator-inbox-specs.md)

## Problem

Paid already pauses work in multiple human-in-the-loop states, but the UI
surfaces were fragmented:

- clarifying-question issues lived in the dashboard needs-input queue
- planning approvals lived on a separate plan-reviews page
- each surface had its own navigation and selection model

That violates the high-level design tenet "No silent stops": when automation
waits, operators need one place to see what is blocked, why it is blocked, and
what action clears it.

## Approach

Introduce a small typed inbox abstraction that merges human-actionable queue
entries into one responsive page.

1. `Inbox::Queue` collects inbox entries the signed-in user can act on.
2. Each entry declares a `kind`, the project/issue context, waiting timestamp,
   and the payload needed to render its detail pane.
3. The inbox renders at `/inbox` and `/inbox/:entry_id`:
   - a desktop split-pane layout with the queue on the left and detail on the
     right, both halves going through the shared
     [`list-detail-layout`](../list-detail-layout/list-detail-layout-design.md)
     shell (`grid gap-6 lg:grid-cols-[22rem_minmax(0,1fr)]`, `22rem` list pane,
     shared pane chrome, shared empty state, shared active-row treatment)
   - a mobile master-detail flow where the member route opens the detail pane
   - a neutral `Waiting —` label when a legacy entry has no waiting timestamp
4. Existing action endpoints stay as the mutation surface:
   - clarifying-question answers still post through
     `Projects::ClarifyingQuestionsController`
   - planning approvals/rejections/revisions still post through
     `PlanReviewsController`, which signals the Temporal workflow

The shared two-pane shell, pane chrome, empty state, and active-row treatment
(`LIST-DETAIL-001`–`LIST-DETAIL-006`) are not inbox-specific — Chat
(`/chat`, `/chat/:id`) renders through the same shell. The Inbox keeps its
own route-based mobile flow (`OPERATOR-INBOX-003`) and its own
`inbox-master-detail` Stimulus controller; only the layout rules move to the
shared pattern.

## Entry Kinds

### `clarifying_questions`

Backed by `Dashboard::NeedsInputQueue`, preserving the existing project
visibility and question parsing rules. The inbox wraps each queue row with a
typed entry, constructs selection links through one shared helper, and
distinguishes issue-backed vs. PR-backed rows with a secondary badge and
GitHub-link label (`View Issue` / `View PR`) so future PR-specific inbox kinds
reuse the same presentation rules instead of forking them.

Producer-side note: the inbox and answer form now support PR-backed records
end-to-end when the record already has parseable clarifying questions in its
body or persisted `needs_input_questions`. As of August 26, 2026, the shipped
question-producing flows remain issue-centric: `enhance_issue` and
`create_feature` persist clarifying questions for issue records, and
`FetchIssuesActivity` still skips PR rows in the enhancement recheck /
questionless-repair paths. That producer gap is intentional follow-up work, not
an inbox rendering constraint.

When the operator opens a clarifying-question entry from the inbox,
the answer flow resolves queue membership and next-entry traversal from
`Inbox::Queue` filtered to `clarifying_questions`, so PR-backed records keep
the same continuation behavior as issue-backed records.

The entry payload also carries the agent-authored context that surrounded
the numbered questions in the latest enhancement comment — the
"Current Context" section plus the prose that introduced the
`## Clarifying questions` heading — as `context_markdown`, surfaced by
`ClarifyingQuestions::Load#context_markdown` reusing the cached
`issue_comments` list the queue already loads. The inbox detail pane
(`OPERATOR-INBOX-011`) renders that markdown beside the answer form on `lg+`
viewports (two-column grid, sticky scrollable sidebar) and inside a
collapsible native `<details>` disclosure above the questions on smaller
viewports, via the shared `shared/markdown_text` partial in block mode.
The panel hides gracefully when no context is fetchable (no GitHub
credential, transient GitHub failure, or questions sourced from the local
`needs_input_questions` snapshot rather than a fetched comment); the
existing `View Issue` / `View PR` link remains so the operator can still
read the comment directly on GitHub.

### `plan_review`

Backed by `DecompositionDecision.open_plan_reviews`, scoped through
`PlanReviewPolicy::Scope`. The entry payload includes the proposed task list so
the inbox detail pane can show the breakdown and submit approve/reject/revise
actions without leaving the inbox.

### `action_required`

Backed by `NotificationPolicy::Scope.new(user, Notification).resolve
.active.blocking`, not by a separate inbox table. This kind covers work that
has halted and cannot self-resolve, so the persisted notification itself is
the source of truth for both bell badging and inbox derivation.

The entry payload carries the source notification, the related
project/issue/run context when it can be derived from the subject, and
remediation guidance from notification metadata (`recommended_action`, plus
optional `remediation_steps` / `remediation_context`).

### `merge_approval`

Backed by the PR scanner's persisted auto-merge blocker snapshot on `Issue`.
The inbox only surfaces PRs whose failed blockers are approval-only
(`owner_approved` and/or `reviews_fresh`) and whose `not_evaluated` blocker
list is empty, so red CI, merge conflicts, unresolved review threads, and
unresolved dependencies stay out of the human-approval queue. The detail pane
reuses the standard PR badge and GitHub-link conventions and directs the
operator to re-approve on GitHub, after which the next scan naturally removes
the entry.

### `escalated_pr`

Backed by `Dashboard::BlockedPullRequests`, the same query the dashboard's
Blocked PRs panel uses — `Inbox::Queue` calls it and filters the result to the
operator's auto-pick-gated projects rather than reimplementing the escalated-PR
query. This is a deliberate scoping divergence: every other inbox kind is
auto-pick + owner scoped (`INBOX-FOUNDATION-006`), while the dashboard panel is
account-wide, so the two surfaces will not agree on counts. That is intentional
— the Inbox stays consistent with itself rather than adopting the dashboard's
broader scope for one kind — and is recorded here so the divergence reads as a
decision, not drift.

The entry payload carries the `Dashboard::BlockedPullRequests::Entry` as its
`record`, so the detail pane shows the same reason, tripped counters,
`last_progress_at`, and operator-paused indicator the dashboard panel shows —
one query, two surfaces, no duplicated blocked-PR logic. The detail pane offers
the same `unblock_escalation` action (`PullRequests::Unblock`,
`PR-ESCALATION-014`) the dashboard panel offers, for every escalation reason
except `awaiting_approval`; that reason denotes an unanswered human gate, not
agent failure, so its entry directs the operator to re-approve on GitHub
instead (mirroring the `merge_approval` kind's re-approval copy) rather than
offering a clearing action that does not apply.

A single kind covers all five escalation reasons rather than splitting
`awaiting_approval` into its own kind: the only behavioral difference is which
action the detail pane offers, which the entry already branches on by reason,
the same way `unblock_confirmation_text` already does for the dashboard panel.
Splitting into two kinds would add a nav filter and count-badge distinction for
one copy difference.

Because the entry is derived from `pr_review_phase` directly rather than a
separate notification, an `awaiting_approval` escalation does not vanish from
the inbox when a PR crosses from `ready` (where it may already have been a
`merge_approval` entry, if blocked only on approval) into `escalated` — it
just changes kind. This closes the gap the dashboard-only surface left: before
this kind existed, that transition silently dropped the PR from the Inbox and
its nav badge at the exact moment it became more urgent.

### `retry_limited`

Backed by `Issue#runner_retry_abandoned_at` directly (the same column the
runner-retry-cap path writes via `Issue#abandon_due_to_runner_retry_cap!` and
the push-permission path writes via `Issue#abandon_due_to_push_permission_rejection!`,
which share an abandonment gate but encode different causes). Before this kind
existed, both abandonments were dashboard-only — visible on the
Retry-Limited card (#2674) but absent from the Inbox and its nav badge, so
operators only learned about the block by scrolling the dashboard, and the
dashboard card had no action buttons. The HLD tenet "No silent stops" requires
the system to surface *that* automation stopped, *why*, and *what clears it*
the same way it surfaces `manual_review`; this kind closes that gap (#3902).

The query is `paid_state`-agnostic (the abandonment gate is independent of
`paid_state`, and the dashboard card deliberately surfaces both issues and PRs
that hit the cap), so it filters on `runner_retry_abandoned_at IS NOT NULL` and
`github_state = "open"` only. It reuses the same auto-pick + owner scoping
(`INBOX-FOUNDATION-006`) every other kind uses, the same divergence from the
dashboard's account-wide scope that `escalated_pr` and `manual_review` already
record (`OPERATOR-INBOX-002C`, `OPERATOR-INBOX-002D`).

The entry payload carries `runner_retry_abandon_reason` as the summary and
distinguishes `push_permission_abandoned?` (prefixed `Push rejected:` — the
GitHub App installation token lacked the permission) from the runner-retry-cap
case in the list and detail views via the same Push Blocked vs Retry Cap badge
split the dashboard card already shows. `waiting_since` is
`runner_retry_abandoned_at`; both producers stamp the timestamp on
abandonment, so there are no legacy nulls to worry about. The clearing path is
the existing `clear_runner_retry_abandonment!` (called from
`RunAgentActivity` on a successful run), the same producer the abandonment
flag already has — no inbox-side controller change is needed, just the cache
invalidation that `Issue#inbox_count_cache_invalidation_needed?` adds for
`saved_change_to_runner_retry_abandoned_at?`.

The detail pane offers the same path the dashboard card implies but does not
actually render: link to the GitHub issue/PR (the operator needs to read the
failure surface anyway) plus a per-project "Start manual run" hint pointing at
the project's runs page. The operator-facing action is the existing
`clear_runner_retry_abandonment!` path on a successful manual run, so there is
no new endpoint to introduce — the kind exists to make the abandonment
discoverable, not to invent a new clearing workflow. The entry leaves the lane
when `clear_runner_retry_abandonment!` runs (on a successful manual run) or
when the underlying GitHub issue closes; both transitions are already covered
by the cache invalidation `saved_change_to_runner_retry_abandoned_at?` adds to
`Issue#inbox_count_cache_invalidation_needed?`.

### `manual_review`

Backed by `Issue#paid_state == "manual_review"` directly, the same way
`clarifying_questions` and `escalated_pr` derive from state rather than a
separate notification. Before this kind existed, `manual_review` was a hard
automation stop with no inbox lane, no dashboard panel, and no notification —
the HLD tenet "No silent stops" requires the system to surface *that*
automation stopped, *why*, and *what clears it*; a project's whole dependency
graph could sit parked behind a `manual_review` root for days with zero
operator-visible signal (issue #3788).

The entry payload carries the issue's `manual_review_reason` (the message
`IssueEnhancements::StopForManualReview` was given, or the equivalent
round-limit copy when `EnhanceIssueActivity` sets the state directly without
going through that service) as its summary, and `manual_review_started_at`
(falling back to `updated_at` for legacy rows predating the column —
`ISSUE-ENHANCEMENT-012`) as its waiting-since timestamp. The detail pane
offers a "Start enhancement run" action that queues a manual `enhance_issue`
run for the issue: per `ISSUE-ENHANCEMENT-011`, automatic picking excludes
`manual_review` and only an explicit operator-triggered run resumes work —
the queueing is the resume, so (unlike `unblock_escalation`, which clears
state directly) this action still creates a run rather than just flipping
state. The same request also transitions the issue out of `manual_review`
(`paid_state: "in_progress"`, the state `CreateAgentRunActivity` sets when
the run starts), inside the same transaction that creates the run, so the
entry leaves the queue and the nav badge at queue time (#3853) instead of
surviving the whole queue wait — the operator-inbox invariant "acting on an
item removes it now" that every other lane already satisfies. The existing
`sync_manual_review_started_at` callback clears the lane columns on exit and
bumps the badge cache version; no inbox-side cache work is needed. A stale
or double click degrades to "This issue is no longer waiting for manual
review." instead of an active-run error.

When the parked state still has clarifying questions stored — preserved by
`EnhanceIssueActivity` when the terminal round's comment has a parseable
`## Clarifying questions` section, and kept by
`IssueEnhancements::StopForManualReview` on every stop path
(`ISSUE-ENHANCEMENT-011`) — `manual_review_entries` carries them on the
entry's `questions` the same local-only way `clarifying_question_entries`
does (`Array(issue.needs_input_questions)`, no GitHub round-trip during queue
listing). The detail pane then renders the same answer form
`clarifying_questions` entries use (shared partial, sans the agent-context
sidebar, which is scoped to the `clarifying_questions` kind), plus the "Start
enhancement run" action, so answering the questions the agent asked on its
final round is itself an operator-triggered manual review. Submitting posts
the standard answer-marker comment and calls
`ClarifyingQuestions::ClearNeedsInput`, which now also treats
`paid_state == "manual_review"` as a clearable source state: it resets
`enhance_issue_rounds` to 0 (the same human-signal reset a `needs_input`
answer already gets) and moves the issue out of the lane — to `new`, or,
when a `create_feature` run is paused on the issue (RDR-053), by resuming
that run under the same `in_progress` queue-time flip an operator-triggered
run gets, so the resume path cannot leave the issue lingering in a lane
auto-pick skips. An issue whose local lookup finds no questions (nothing
stored, nothing parseable in the body) falls back to the state + "Start
enhancement run" button only, as before.
GitHub in-thread answers are not auto-detected for `manual_review` —
`FetchIssuesActivity`'s needs-input recovery paths gate on
`paid_state: needs_input` only — so the inbox answer form is the only
recovery surface for a parked terminal round's questions.

The item returns only when the resumed work itself needs another human
decision, through the existing re-entry producers: an unparseable
enhancement (`IssueEnhancements::StopForManualReview`), the configured round
limit again (`EnhanceIssueActivity#paid_state_for`), or clarifying questions
(the `needs_input` lane). A `sufficient_context: true` verdict correctly
does not return it (`completed` + `create_pr` follow-up). If the queued run
fails, generic failure handling applies (`paid_state: "failed"`, auto-pick
eligible, so generic re-evaluation — not a silent stranding); if it is
cancelled before starting, the issue stays `in_progress` exactly like any
other cancelled run, with `StaleRunDetectorJob`'s orphaned-in_progress
recovery as the backstop. The same queue-time flip covers a `manual_review`
issue queued through the bulk enhance form, which is equally
operator-triggered.

Scoping follows `INBOX-FOUNDATION-006` like every other kind (auto-pick +
owner gated), not the dashboard's broader account-wide scope — the same
divergence-recording rationale as `escalated_pr` (`OPERATOR-INBOX-002C`).

`Dashboard::EligibilityBreakdown` names `manual_review` as its own bucket
(previously it fell into the unnamed `other_excluded` remainder), so the
account-wide breakdown panel and the scoped inbox lane agree on what the
state means, even though their scopes differ.

## Navigation

The inbox is a top-level nav item (desktop and mobile), placed immediately
after Dashboard and before Projects, with an unread-style count badge — the
same first-class placement as the notifications bell.

A full `Inbox::Queue.call` per page render is too heavy for the nav: it loads
issue bodies to parse clarifying questions, runs the auto-pick project gate,
and queries open plan reviews. So the badge is async, not inline:

1. The nav renders a lazy Turbo Frame (`inbox_nav_badge_desktop` /
   `inbox_nav_badge_mobile`) pointing at `GET /inbox/count` — the same lazy-frame
   pattern the notification bell's dropdown content already uses. Page render
   never builds the queue.
2. `Inbox::Count` computes an approximate candidate count in a couple of
   indexed queries — no issue bodies, no `ClarifyingQuestions::Parse` — and
   caches it per user for 90 seconds via `Dashboard::CacheVersion` (scope
   `:inbox`), the same account-scoped version-bump pattern
   `Dashboard::QueuePreview` uses.
3. The version bumps on queue-mutating events: `Issue` bumps it whenever
   `needs_input_since` changes or a waiting issue flips `github_state`
   between open/closed (covers entering needs_input, answer submission,
   manual-review escalation, and direct GitHub close/reopen without waiting
   for TTL expiry); `Orchestration::DecompositionDecisions::Log` bumps it on
   every decision write (covers both a new pending plan review appearing and
   an existing one resolving, since `open_plan_reviews` reads the latest
   decision per workflow).
4. The count is intentionally approximate: it includes `needs_input` rows
   without checking whether they have parseable questions yet (questionless
   rows are rare and self-repair during sync), trading exactness for staying
   a couple of single-purpose indexed queries instead of an
   `Inbox::Queue`-shaped scan. Drift is bounded to that one edge case and a
   TTL window.

Future inbox kinds extend the count the same way `Inbox::Queue` extends: add
the candidate query to `Inbox::Count` and a matching cache-bump site, no nav
or controller changes needed. `action_required` uses notification lifecycle
updates as its cache-bump source. `escalated_pr` needed no new cache-bump
site: `Issue#merge_approval_candidate_state_changed?` already watches
`saved_change_to_pr_review_phase?` for every pull request (despite its name,
it is not merge-approval-specific), so a transition into or out of
`escalated` already bumps `Dashboard::CacheVersion::INBOX_SCOPE` today.
`manual_review` follows the `sync_needs_input_since` precedent instead: a
`sync_manual_review_started_at` callback stamps/clears
`manual_review_started_at` on `paid_state` transitions, and
`saved_change_to_manual_review_started_at?` joins the cache-invalidation
predicate the same way `saved_change_to_needs_input_since?` already does.

## Decisions

- **One queue service, not per-page queries**: the inbox page and any future
  queue consumers should share one typed discovery path.
- **Legacy routes remain as aliases**: `/dashboard/needs_input` and
  `/plan_reviews` redirect to the inbox instead of rendering parallel surfaces.
- **Selection is route-based**: `/inbox` renders the first actionable entry
  and `/inbox/:entry_id` renders that member route as the explicit detail
  state, with stale member paths redirecting to `/inbox` instead of silently
  selecting a different record.
- **Missing waiting timestamps remain visible**: legacy entries with a nullable
  waiting timestamp stay actionable and render `Waiting —` instead of deriving
  an inaccurate age or failing the inbox page.
- **`retry_limited` shares the cache-invalidation pattern with
  `manual_review`**: the abandonment timestamp flips on
  `abandon_due_to_runner_retry_cap!` /
  `abandon_due_to_push_permission_rejection!` and on
  `clear_runner_retry_abandonment!`, so
  `saved_change_to_runner_retry_abandoned_at?` joins
  `Issue#inbox_count_cache_invalidation_needed?` the same way
  `saved_change_to_manual_review_started_at?` already does
  (`OPERATOR-INBOX-002D`). No bespoke callback needed — the abandonment and
  clearing producers write the timestamp, the existing
  `after_commit :bump_inbox_cache_version` callback picks up the change.
- **Temporal signaling remains controller-driven**: the inbox changes the UI
  surface, not the workflow contract. `approve_plan`, `reject_plan`, and
  `revise_plan` remain the bridge into `Workflows::PlanningWorkflow`.

## Testing

- `spec/services/inbox/queue_spec.rb` covers typed discovery of
  clarifying-question, plan-review, merge-approval, and action-required
  entries.
- `spec/requests/dashboard_spec.rb` covers legacy dashboard redirects into the
  inbox.
- `spec/requests/inbox_spec.rb` covers the inbox layouts, member selection,
  stale-entry redirects, and action-required detail rendering.
- `spec/system/inbox_chat_popup_spec.rb` drives a real browser and asserts
  the desktop split-pane's actual geometry (queue and detail side by side,
  not stacked as two rows) in addition to its existing pane-visibility and
  mobile-collapse coverage — `spec/system/dashboard_inbox_spec.rb`'s
  `:rack_test` driver never applies CSS, so it cannot catch a broken grid
  declaration (#3876).
- `spec/requests/plan_reviews_spec.rb` covers signal dispatch and inbox
  redirects after review actions.
- `spec/requests/projects/clarifying_questions_spec.rb` covers inbox queue
  return/next-navigation through the existing answer form.
- `spec/requests/navigation_spec.rb` covers top-level nav placement, Insights
  dropdown removal, and the lazy badge frame markup.
- `spec/requests/inbox_spec.rb` also covers `GET /inbox/count` badge
  rendering (zero/hidden, count, `99+` cap).
- `spec/services/inbox/count_spec.rb` covers the approximate count query and
  cache invalidation on needs_input transitions and decision writes.
- `spec/services/inbox/queue_spec.rb` and `spec/services/inbox/count_spec.rb`
  cover `escalated_pr` discovery, scoping, and cache invalidation on
  `pr_review_phase` transitions into and out of `escalated`.
- `spec/requests/inbox_spec.rb` covers `escalated_pr` detail rendering
  (agent-failure reasons vs. `awaiting_approval`) and the inbox-scoped
  `return_to` on the Unblock action.
- `spec/requests/agent_runs_spec.rb` covers `unblock_escalation`'s
  inbox-aware redirect.
- `spec/services/inbox/queue_spec.rb` and `spec/services/inbox/count_spec.rb`
  cover `manual_review` discovery, scoping, and cache invalidation on
  `paid_state` transitions into and out of `manual_review`.
- `spec/services/inbox/queue_spec.rb` and `spec/services/inbox/count_spec.rb`
  cover `retry_limited` discovery (including the
  `push_permission_abandoned?` Push Blocked vs Retry Cap distinction), the
  same auto-pick + owner scoping the other gated kinds use, and cache
  invalidation on `runner_retry_abandoned_at` transitions into and out of
  the lane via `clear_runner_retry_abandonment!` and the
  runner-retry-cap / push-permission abandonment producers.
- `spec/requests/inbox_spec.rb` covers `manual_review` detail rendering (reason,
  age, and the `resume_manual_review` action).
- `spec/requests/agent_runs_spec.rb` covers `resume_manual_review` queuing a
  manual `enhance_issue` run, its inbox-aware redirect, the queue-time
  `manual_review` → `in_progress` transition (state/lanes/badge on success,
  state preserved on budget/no-runner failure, graceful stale re-click), and
  the same flip through the bulk enhance form.
- `spec/services/dashboard/eligibility_breakdown_spec.rb` covers the named
  `manual_review` bucket.
