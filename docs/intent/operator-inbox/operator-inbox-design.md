# Design: Operator Inbox

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
     right
   - a mobile master-detail flow where the member route opens the detail pane
   - a neutral `Waiting —` label when a legacy entry has no waiting timestamp
4. Existing action endpoints stay as the mutation surface:
   - clarifying-question answers still post through
     `Projects::ClarifyingQuestionsController`
   - planning approvals/rejections/revisions still post through
     `PlanReviewsController`, which signals the Temporal workflow

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

### `plan_review`

Backed by `DecompositionDecision.open_plan_reviews`, scoped through
`PlanReviewPolicy::Scope`. The entry payload includes the proposed task list so
the inbox detail pane can show the breakdown and submit approve/reject/revise
actions without leaving the inbox.

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
- **Temporal signaling remains controller-driven**: the inbox changes the UI
  surface, not the workflow contract. `approve_plan`, `reject_plan`, and
  `revise_plan` remain the bridge into `Workflows::PlanningWorkflow`.

## Testing

- `spec/services/inbox/queue_spec.rb` covers typed discovery of
  clarifying-question and plan-review entries.
- `spec/requests/dashboard_spec.rb` covers legacy dashboard redirects into the
  inbox.
- `spec/requests/inbox_spec.rb` covers the inbox layouts, member selection,
  and stale-entry redirects.
- `spec/requests/plan_reviews_spec.rb` covers signal dispatch and inbox
  redirects after review actions.
- `spec/requests/projects/clarifying_questions_spec.rb` covers inbox queue
  return/next-navigation through the existing answer form.
