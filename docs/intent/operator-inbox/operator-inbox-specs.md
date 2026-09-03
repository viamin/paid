# EARS Specs: Operator Inbox

> Testable claims for the unified operator inbox.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r OPERATOR-INBOX-001`).

- [x] **OPERATOR-INBOX-001** — When a signed-in user opens the inbox, the
  system SHALL list actionable clarifying-question entries drawn from the
  existing needs-input queue, preserving the user's project visibility and any
  explicit project scope filter.
  *Code:* `app/services/inbox/queue.rb`, `app/controllers/inbox_controller.rb`.
  *Test:* `spec/services/inbox/queue_spec.rb`, `spec/requests/inbox_spec.rb`.

- [x] **OPERATOR-INBOX-002** — When a planning workflow records an open
  `plan_pending_review` decomposition decision and the user can manage the
  project, the system SHALL expose that pending review as a `plan_review`
  inbox entry until a later workflow decision closes it.
  *Code:* `app/services/inbox/queue.rb`, `app/models/decomposition_decision.rb`.
  *Test:* `spec/services/inbox/queue_spec.rb`.

- [x] **OPERATOR-INBOX-002A** — When an open PR's persisted auto-merge blocker
  snapshot reduces to approval-only failures (`owner_approved` and/or
  `reviews_fresh`) with no other failed or not-evaluated blockers, the system
  SHALL expose that PR as a `merge_approval` inbox entry until a later PR scan
  records a non-approval blocker, a fresh approval, or a merge/close outcome.
  *Code:* `app/services/inbox/queue.rb`, `app/services/inbox/merge_approval.rb`.
  *Test:* `spec/services/inbox/queue_spec.rb`, `spec/requests/inbox_spec.rb`.

- [x] **OPERATOR-INBOX-002B** — When a visible notification is active and
  `blocking: true`, the system SHALL expose it as an `action_required` inbox
  entry until the notification resolves or is dismissed, reusing notification
  metadata for remediation copy instead of introducing a separate persistence
  model.
  *Code:* `app/services/inbox/queue.rb`, `app/services/inbox/count.rb`.
  *Test:* `spec/services/inbox/queue_spec.rb`, `spec/requests/inbox_spec.rb`,
  `spec/services/inbox/count_spec.rb`.

- [x] **OPERATOR-INBOX-002C** — When an open pull request's review phase is
  `escalated` and its project is in the operator's auto-pick-gated scope
  (`INBOX-FOUNDATION-006`, the same gate every other inbox kind uses — this is
  a deliberate divergence from the dashboard's account-wide Blocked PRs panel,
  so the two surfaces are not expected to agree on counts), the system SHALL
  expose that pull request as an `escalated_pr` inbox entry showing the
  escalation reason, how long it has been stopped (`pr_escalation_started_at`,
  falling back to `updated_at`), and the tripped counters computed by
  `Dashboard::BlockedPullRequests` (reused, not reimplemented), including its
  operator-paused indicator when the pull request is both escalated and
  paused. The entry SHALL offer the `unblock_escalation` clearing action for
  every reason except `awaiting_approval`, for which the entry SHALL instead
  direct the operator to re-approve the pull request on GitHub. The entry
  SHALL clear on every recovery path the escalation itself clears through
  (label removal, draft conversion, Unblock from either the dashboard or the
  inbox, and operational auto-dismissal), and an escalation with reason
  `awaiting_approval` SHALL remain a visible inbox entry across the `ready` →
  `escalated` transition rather than disappearing from the queue and the nav
  badge.
  *Code:* `app/services/inbox/queue.rb`, `app/services/inbox/count.rb`,
  `app/controllers/projects/agent_runs_controller.rb`,
  `app/views/dashboard/_inbox_detail_escalated_pr.html.erb`.
  *Test:* `spec/services/inbox/queue_spec.rb`, `spec/services/inbox/count_spec.rb`,
  `spec/requests/inbox_spec.rb`, `spec/requests/agent_runs_spec.rb`.

- [x] **OPERATOR-INBOX-002D** — When an open issue's `paid_state` is
  `manual_review` and its project is in the operator's auto-pick-gated scope
  (`INBOX-FOUNDATION-006`, the same gate every other inbox kind uses), the
  system SHALL expose that issue as a `manual_review` inbox entry showing why
  automation stopped (`manual_review_reason`) and how long it has been stopped
  (`manual_review_started_at`, falling back to `updated_at` for legacy rows —
  `ISSUE-ENHANCEMENT-012`). The entry SHALL offer an operator-triggered manual
  `enhance_issue` run as its clearing action, since automatic picking excludes
  `manual_review` and only an explicit operator-triggered run resumes work
  (`ISSUE-ENHANCEMENT-011`). The entry SHALL clear when the issue leaves
  `manual_review` or its underlying GitHub issue closes.
  `Dashboard::EligibilityBreakdown` SHALL report `manual_review` as its own
  named bucket instead of folding it into the unnamed `other_excluded`
  remainder, and `Inbox::Count`'s cached badge SHALL invalidate on transitions
  into and out of `manual_review` via `Dashboard::CacheVersion`'s `INBOX_SCOPE`.
  *Code:* `app/services/inbox/queue.rb`, `app/services/inbox/count.rb`,
  `app/services/dashboard/eligibility_breakdown.rb`, `app/models/issue.rb`,
  `app/controllers/projects/agent_runs_controller.rb`,
  `app/views/dashboard/_inbox_detail_manual_review.html.erb`.
  *Test:* `spec/services/inbox/queue_spec.rb`, `spec/services/inbox/count_spec.rb`,
  `spec/services/dashboard/eligibility_breakdown_spec.rb`,
  `spec/requests/inbox_spec.rb`, `spec/requests/agent_runs_spec.rb`.

- [x] **OPERATOR-INBOX-003** — When the inbox renders on desktop, the system
  SHALL show the queue list and the selected entry detail at the same time; on
  mobile, the system SHALL support a master-detail flow where the member route
  opens the detail pane with a path back to the list.
  *Code:* `app/controllers/inbox_controller.rb`,
  `app/views/inbox/index.html.erb`,
  `app/views/dashboard/_inbox_list.html.erb`,
  `app/views/dashboard/_inbox_detail.html.erb`,
  `app/javascript/controllers/inbox_master_detail_controller.js`.
  *Test:* `spec/requests/inbox_spec.rb`, `spec/system/dashboard_inbox_spec.rb`.

- [x] **OPERATOR-INBOX-003A** — While the inbox page initializes, the inbox
  master-detail controller SHALL complete its Stimulus lifecycle without
  raising — including when Stimulus invokes its value-change callback before
  `connect()` and when `disconnect()` runs after an interrupted setup — so
  other controllers on the page, such as the global chat-popup button,
  still become interactive.
  *Code:* `app/javascript/controllers/inbox_master_detail_controller.js`.
  *Test:* `spec/system/inbox_chat_popup_spec.rb`.

- [x] **OPERATOR-INBOX-004** — When a user approves, rejects, or revises a
  pending plan review from the inbox, the system SHALL signal the planning
  workflow through the existing Temporal bridge and SHALL redirect back to the
  inbox so the cleared entry no longer remains selected.
  *Code:* `app/controllers/plan_reviews_controller.rb`.
  *Test:* `spec/requests/plan_reviews_spec.rb`.

- [x] **OPERATOR-INBOX-005** — When the user reaches clarifying questions from
  the inbox queue, the system SHALL preserve the validated inbox return target
  and SHALL return to that inbox scope after the queue is exhausted.
  *Code:* `app/controllers/projects/clarifying_questions_controller.rb`.
  *Test:* `spec/requests/projects/clarifying_questions_spec.rb`.

- [x] **OPERATOR-INBOX-006** — When an actionable inbox entry has no waiting
  timestamp, the system SHALL keep the entry visible and SHALL render
  `Waiting —` in both the queue list and selected-entry detail instead of
  deriving an age or failing the inbox page.
  *Code:* `app/views/inbox/index.html.erb`,
  *Code:* `app/views/dashboard/_inbox_list.html.erb`,
  `app/views/dashboard/_inbox_detail.html.erb`.
  *Test:* `spec/requests/inbox_spec.rb`.

- [x] **OPERATOR-INBOX-007** — When a clarifying-question inbox entry is backed
  by a pull request record, the system SHALL load that PR through the existing
  clarifying-questions controller, SHALL preserve the inbox answer flow and
  local needs-input clearing behavior, and SHALL render a distinct `PR` badge
  plus PR-aware GitHub link copy anywhere the inbox distinguishes issues from
  pull requests.
  *Code:* `app/controllers/projects/clarifying_questions_controller.rb`,
  `app/helpers/dashboard_helper.rb`,
  `app/helpers/issues_helper.rb`,
  `app/views/inbox/index.html.erb`,
  `app/views/dashboard/_inbox_list.html.erb`,
  `app/views/dashboard/_inbox_detail.html.erb`,
  `app/views/dashboard/_inbox_detail_clarifying_questions.html.erb`,
  `app/services/clarifying_questions/clear_needs_input.rb`.
  *Test:* `spec/requests/inbox_spec.rb`,
  `spec/requests/projects/clarifying_questions_spec.rb`,
  `spec/services/clarifying_questions/clear_needs_input_spec.rb`.

- [x] **OPERATOR-INBOX-008** — When a clarifying-question inbox entry is
  selected, the system SHALL render every question and answer field inline in
  the detail pane as a single one-page form; on successful submission the
  system SHALL auto-advance the detail pane to the next actionable entry in
  the operator's current scope (or the drained empty state); on a validation
  or GitHub-post failure the system SHALL redirect back into the same detail
  frame and SHALL repopulate the submitted answers from a one-shot flash so
  the operator does not retype them, bounded to a byte budget that keeps the
  serialized session cookie under its size ceiling.
  *Code:* `app/controllers/projects/clarifying_questions_controller.rb`,
  `app/views/dashboard/_inbox_detail_clarifying_questions.html.erb`.
  *Test:* `spec/requests/projects/clarifying_questions_spec.rb`.

- [x] **OPERATOR-INBOX-009** — When a signed-in user opens `/inbox/:entry_id`
  for a stale or invalid entry in their current queue scope, the system SHALL
  redirect to `/inbox` with `303 See Other` instead of silently selecting the
  first available entry or returning a `404`.
  *Code:* `app/controllers/inbox_controller.rb`,
  `app/controllers/legacy_inbox_redirects_controller.rb`.
  *Test:* `spec/requests/inbox_spec.rb`, `spec/requests/dashboard_spec.rb`.

- [x] **OPERATOR-INBOX-010** — When a signed-in user views the main
  navigation (desktop or mobile), the system SHALL render Inbox as a
  top-level, unscoped nav item immediately after Dashboard and before
  Projects, SHALL NOT list it in the Insights dropdown, and SHALL render its
  unread-style count badge as a lazy Turbo Frame backed by a short-TTL,
  per-user cached count at `GET /inbox/count` so ordinary page renders never
  build `Inbox::Queue`. The cached count SHALL invalidate when an issue enters
  or leaves the needs_input queue, when a needs_input issue closes or reopens
  on GitHub, and on decomposition-decision writes (plan review creation and
  resolution), and SHALL render capped at `99+` and hidden at zero, matching
  the bell's badge markup classes.
  *Code:* `app/views/layouts/application.html.erb`,
  `app/controllers/inbox_controller.rb`, `app/services/inbox/count.rb`,
  `app/services/dashboard/cache_version.rb`, `app/models/issue.rb`,
  `app/services/orchestration/decomposition_decisions/log.rb`,
  `app/views/inbox/count.html.erb`, `app/views/inbox/_count_badge.html.erb`.
  *Test:* `spec/requests/navigation_spec.rb`, `spec/requests/inbox_spec.rb`,
  `spec/services/inbox/count_spec.rb`.
