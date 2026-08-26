# EARS Specs: Operator Inbox

> Testable claims for the unified operator inbox.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r OPERATOR-INBOX-001`).

- [x] **OPERATOR-INBOX-001** — When a signed-in user opens the inbox, the
  system SHALL list actionable clarifying-question entries drawn from the
  existing needs-input queue, preserving the user's project visibility and any
  explicit project scope filter.
  *Code:* `app/services/inbox/queue.rb`, `app/controllers/dashboard_controller.rb`.
  *Test:* `spec/services/inbox/queue_spec.rb`, `spec/requests/dashboard_spec.rb`.

- [x] **OPERATOR-INBOX-002** — When a planning workflow records an open
  `plan_pending_review` decomposition decision and the user can manage the
  project, the system SHALL expose that pending review as a `plan_review`
  inbox entry until a later workflow decision closes it.
  *Code:* `app/services/inbox/queue.rb`, `app/models/decomposition_decision.rb`.
  *Test:* `spec/services/inbox/queue_spec.rb`.

- [x] **OPERATOR-INBOX-003** — When the inbox renders on desktop, the system
  SHALL show the queue list and the selected entry detail at the same time; on
  mobile, the system SHALL support a master-detail flow where selecting an
  entry opens the detail pane with a path back to the list.
  *Code:* `app/views/dashboard/inbox.html.erb`,
  `app/views/dashboard/_inbox_list.html.erb`,
  `app/views/dashboard/_inbox_detail.html.erb`.
  *Test:* `spec/requests/dashboard_spec.rb`.

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
  *Code:* `app/views/dashboard/_inbox_list.html.erb`,
  `app/views/dashboard/_inbox_detail.html.erb`.
  *Test:* `spec/requests/dashboard_spec.rb`.

- [x] **OPERATOR-INBOX-007** — When a clarifying-question inbox entry is backed
  by a pull request record, the system SHALL load that PR through the existing
  clarifying-questions controller, SHALL preserve the inbox answer flow and
  local needs-input clearing behavior, and SHALL render a distinct `PR` badge
  plus PR-aware GitHub link copy anywhere the inbox distinguishes issues from
  pull requests.
  *Code:* `app/controllers/projects/clarifying_questions_controller.rb`,
  `app/helpers/application_helper.rb`,
  `app/views/dashboard/_inbox_list.html.erb`,
  `app/views/dashboard/_inbox_detail.html.erb`,
  `app/views/dashboard/_inbox_detail_clarifying_questions.html.erb`,
  `app/services/clarifying_questions/clear_needs_input.rb`.
  *Test:* `spec/requests/dashboard_spec.rb`,
  `spec/requests/projects/clarifying_questions_spec.rb`,
  `spec/services/clarifying_questions/clear_needs_input_spec.rb`.
