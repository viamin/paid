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

- [x] **OPERATOR-INBOX-003** — When the inbox renders on desktop, the system
  SHALL show the queue list and the selected entry detail at the same time; on
  mobile, the system SHALL support a master-detail flow where the member route
  opens the detail pane with a path back to the list.
  *Code:* `app/controllers/inbox_controller.rb`,
  `app/views/inbox/index.html.erb`,
  `app/views/dashboard/_inbox_list.html.erb`,
  `app/views/dashboard/_inbox_detail.html.erb`.
  *Test:* `spec/requests/inbox_spec.rb`.

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
