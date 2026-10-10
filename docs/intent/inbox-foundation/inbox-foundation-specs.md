# EARS Specs: Inbox Foundation

> Foundation for the unified "inbox" UX that surfaces issues and pull requests
> awaiting human input. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r INBOX-FOUNDATION-001`).

## `needs_input_since` timestamp

- [x] **INBOX-FOUNDATION-001** — When an `Issue` row transitions its
  `paid_state` into `"needs_input"` from any other state, the system SHALL
  stamp `needs_input_since` to the transition time. When the same row
  transitions out of `"needs_input"` to any other state, the system SHALL
  clear `needs_input_since`. A single model callback SHALL own this
  transition logic so every existing write path converges without scattered
  updates. The column SHALL be nullable: `nil` means "not currently awaiting
  input".
  *Tests:* `spec/models/issue_spec.rb`, `spec/services/clarifying_questions/clear_needs_input_spec.rb`.
  *Code:* `app/models/issue.rb#sync_needs_input_since`,
  `app/services/clarifying_questions/clear_needs_input.rb`.

- [x] **INBOX-FOUNDATION-002** — When the create_feature needs-input flow
  resumes a paused agent run without resetting `paid_state` (RDR-053 path
  inside `ClarifyingQuestions::ClearNeedsInput#assemble_and_resume_create_feature!`),
  the system SHALL still clear `needs_input_since` because the issue is no
  longer waiting on a human answer — it is now waiting on the agent run.
  *Tests:* `spec/services/clarifying_questions/clear_needs_input_spec.rb`.
  *Code:* `app/services/clarifying_questions/clear_needs_input.rb#assemble_and_resume_create_feature!`.

## `Inbox::Queue` service

- [x] **INBOX-FOUNDATION-003** — `Inbox::Queue.call(user:, project: nil)` SHALL
  return a list of `Entry` structs with shape
  `kind:, project:, issue:, waiting_since:` plus the payload fields each kind
  renders (`questions:` for `:clarifying_questions`, `tasks:` for
  `:plan_review`, and approval-blocker summary/detail for `:merge_approval`).
  Each entry SHALL be typed by `kind` so future kinds can register without UI
  churn.
  *Tests:* `spec/services/inbox/queue_spec.rb`.
  *Code:* `app/services/inbox/queue.rb`.

- [x] **INBOX-FOUNDATION-004** — `Inbox::Queue` SHALL order entries
  oldest-waiting-first by each entry's `waiting_since ASC` (nulls last), with a stable
  tiebreak of `(projects.owner, projects.repo, issues.github_number,
  issues.id)` so the order is deterministic across calls.
  *Tests:* `spec/services/inbox/queue_spec.rb`.
  *Code:* `app/services/inbox/queue.rb`.

- [x] **INBOX-FOUNDATION-005** — `Inbox::Queue` SHALL include both issues and
  pull requests (i.e. SHALL NOT filter on `is_pull_request`). Open PRs whose
  persisted auto-merge blockers reduce to approval-only failures
  (`owner_approved` and/or `reviews_fresh`) with every other signal green
  SHALL appear as `merge_approval` entries; PRs still blocked on checks,
  conflicts, review threads, or dependencies SHALL NOT appear.
  *Tests:* `spec/services/inbox/queue_spec.rb`.
  *Code:* `app/services/inbox/queue.rb`,
  `app/services/inbox/merge_approval.rb`.

- [x] **INBOX-FOUNDATION-006** — `Inbox::Queue` SHALL scope visibility to the
  operator's *authorized* projects, independent of automatic work-selection
  eligibility: `Project.where(account_id: user.account_id, active: true)`,
  restricted to the user's own projects (plus orphaned-project visibility via
  `AgentRun.orphaned_project_owner?(user)`), and optionally narrowed to a
  single project via `project:`. This scope SHALL NOT filter on
  `auto_pick_enabled` and SHALL NOT apply `Issues::AutoPickProjectGate` (or
  any other automatic-work-selection gate): disabling a project's auto-pick
  SHALL NOT remove its human-review Inbox entries, because authorized
  visibility and automatic work-selection eligibility are independent
  concerns (#4221). A lane MAY still consult per-issue auto-pick eligibility
  as its own business rule (e.g. `partial_closeout`'s stall detection via
  `Automation::Strategies::AutoPick::DefaultCandidateSource`) without
  reintroducing a project-level eligibility filter.
  *Tests:* `spec/services/inbox/queue_spec.rb`.
  *Code:* `app/services/inbox/queue.rb#scoped_projects`,
  `app/services/inbox/queue.rb#visible_projects`,
  `app/services/inbox/queue.rb#visible_owner_ids`.

- [x] **INBOX-FOUNDATION-007** — `Dashboard::NeedsInputQueue` SHALL continue
  to expose its existing `.call`, `.next_issue`, and `Entry` API (with
  `project`/`issue`/`questions`), SHALL delegate to `Inbox::Queue` for the
  queue body, and SHALL apply the `is_pull_request: false` filter on top so
  the `/dashboard/needs_input` page is unchanged during rollout. The existing
  `Dashboard::NeedsInputQueue` spec SHALL stay green.
  *Tests:* `spec/services/dashboard/needs_input_queue_spec.rb`.
  *Code:* `app/services/dashboard/needs_input_queue.rb`.

- [x] **INBOX-FOUNDATION-008** — When an open ready pull request has the
  structured `paid-hold-review` label, `Inbox::Queue` SHALL return it as a
  `merge_approval` entry with a human-review summary even if its ordinary
  auto-merge blocker snapshot is absent or has other blockers.
  *Tests:* `spec/services/inbox/queue_spec.rb`.
  *Code:* `app/services/inbox/merge_approval.rb`.

- [x] **INBOX-FOUNDATION-009** — When an operator opens the Inbox, the system
  SHALL render a compact collapsed filter control. On expansion it SHALL offer
  a single type selector, a searchable selector scoped to projects accessible
  through `policy_scope(Project)`, an All reset for each, oldest/newest waiting
  order, and a clear-all action. The controls SHALL derive their selected state
  solely from `kind`, `project_id`, and `sort` URL parameters; the queue SHALL
  preserve oldest-waiting-first when `sort` is absent and SHALL support
  `sort=newest`. The expanded control SHALL be focus-trapped, close on Escape,
  submit on Enter, and render as a full-screen dialog below the `lg` breakpoint.
  *Tests:* `spec/requests/inbox_spec.rb`, `spec/services/inbox/queue_spec.rb`.
  *Code:* `app/controllers/inbox_controller.rb`, `app/services/inbox/queue.rb`,
  `app/helpers/inbox/path_helper.rb`, `app/views/inbox/index.html.erb`,
  `app/javascript/controllers/inbox_filters_controller.js`.
