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
  `kind: :clarifying_questions, project:, issue:, questions:, waiting_since:`.
  Each entry SHALL be typed by `kind` so future kinds
  (`:plan_review`, `:pr_owner_approval`, `:paused_run_decision`) can register
  without UI churn.
  *Tests:* `spec/services/inbox/queue_spec.rb`.
  *Code:* `app/services/inbox/queue.rb`.

- [x] **INBOX-FOUNDATION-004** — `Inbox::Queue` SHALL order entries
  oldest-waiting-first by `needs_input_since ASC` (nulls last), with a stable
  tiebreak of `(projects.owner, projects.repo, issues.github_number,
  issues.id)` so the order is deterministic across calls.
  *Tests:* `spec/services/inbox/queue_spec.rb`.
  *Code:* `app/services/inbox/queue.rb#ordered_issues`.

- [x] **INBOX-FOUNDATION-005** — `Inbox::Queue` SHALL include both issues and
  pull requests (i.e. SHALL NOT filter on `is_pull_request`). Today no PR
  matches because the existing `needs_input` flow only fires on issues; the
  filter is dropped structurally so the inbox is ready for future
  PR-blocking kinds.
  *Tests:* `spec/services/inbox/queue_spec.rb`.
  *Code:* `app/services/inbox/queue.rb#ordered_issues`.

- [x] **INBOX-FOUNDATION-006** — `Inbox::Queue` SHALL keep the same scoping
  and visibility semantics as `Dashboard::NeedsInputQueue`: auto-pick
  projects only (`Project.where(auto_pick_enabled: true, active: true)`),
  gated by `Issues::AutoPickProjectGate.call`, restricted to the user's own
  projects (plus orphaned-project visibility via
  `AgentRun.orphaned_project_owner?(user)`), and optionally narrowed to a
  single project via `project:`.
  *Tests:* `spec/services/inbox/queue_spec.rb`.
  *Code:* `app/services/inbox/queue.rb#scoped_projects`,
  `app/services/inbox/queue.rb#auto_pick_projects`,
  `app/services/inbox/queue.rb#visible_owner_ids`.

- [x] **INBOX-FOUNDATION-007** — `Dashboard::NeedsInputQueue` SHALL continue
  to expose its existing `.call`, `.next_issue`, and `Entry` API (with
  `project`/`issue`/`questions`), SHALL delegate to `Inbox::Queue` for the
  queue body, and SHALL apply the `is_pull_request: false` filter on top so
  the `/dashboard/needs_input` page is unchanged during rollout. The existing
  `Dashboard::NeedsInputQueue` spec SHALL stay green.
  *Tests:* `spec/services/dashboard/needs_input_queue_spec.rb`.
  *Code:* `app/services/dashboard/needs_input_queue.rb`.
