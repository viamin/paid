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
3. The dashboard inbox renders:
   - a desktop split-pane layout with the queue on the left and detail on the
     right
   - a mobile master-detail flow where selecting an item opens the detail pane
4. Existing action endpoints stay as the mutation surface:
   - clarifying-question answers still post through
     `Projects::ClarifyingQuestionsController`
   - planning approvals/rejections/revisions still post through
     `PlanReviewsController`, which signals the Temporal workflow

## Entry Kinds

### `clarifying_questions`

Backed by `Dashboard::NeedsInputQueue`, preserving the existing project
visibility and question parsing rules. The inbox wraps each queue row with a
typed entry and links to the existing answer form.

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
- **Selection is query-param based**: `entry_kind`, `entry_id`, and `view`
  drive server-rendered selection with no client-side state requirement.
- **Temporal signaling remains controller-driven**: the inbox changes the UI
  surface, not the workflow contract. `approve_plan`, `reject_plan`, and
  `revise_plan` remain the bridge into `Workflows::PlanningWorkflow`.

## Testing

- `spec/services/inbox/queue_spec.rb` covers typed discovery of
  clarifying-question and plan-review entries.
- `spec/requests/dashboard_spec.rb` covers the inbox layouts and legacy-route
  redirects.
- `spec/requests/plan_reviews_spec.rb` covers signal dispatch and inbox
  redirects after review actions.
- `spec/requests/projects/clarifying_questions_spec.rb` covers inbox queue
  return/next-navigation through the existing answer form.
