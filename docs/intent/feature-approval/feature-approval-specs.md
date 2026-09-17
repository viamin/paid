# EARS Specs: Feature Approval (Inbox)

> RDR-066 feature-design decision flow and "Mark approved" action, surfaced
> through the existing typed Inbox (`docs/intent/inbox-foundation/`,
> `docs/intent/operator-inbox/`). Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r FEATURE-APPROVAL-001`).

## Open decisions

- [x] **FEATURE-APPROVAL-001** — A `FeatureIntentDecision` of kind
  `question` SHALL record the prompt text and the design claim it affects,
  and SHALL stay `open` until a human resolves it with an answer, actor, and
  timestamp.
  *Tests:* `spec/models/feature_intent_decision_spec.rb`.
  *Code:* `app/models/feature_intent_decision.rb`.

- [x] **FEATURE-APPROVAL-002** — A `FeatureIntentDecision` of kind
  `inferred_decision` SHALL represent an AI-inferred assumption that requires
  explicit human confirmation before it counts as resolved; resolving it
  SHALL use the same `resolve!` path as a question.
  *Tests:* `spec/models/feature_intent_decision_spec.rb`.
  *Code:* `app/models/feature_intent_decision.rb`.

## Design PR tracking and staleness

- [x] **FEATURE-APPROVAL-003** — A `FeatureIntentDesignPr` SHALL track a
  linked design pull request's `head_sha` alongside a `reviewed_head_sha` —
  the head its open decisions/evidence were last generated against — and
  SHALL report `stale?` when the two diverge, so a commit landing after
  discovery is never silently approved on stale evidence. Only PRs where
  `required: true` block readiness; optional artifacts going stale does not.
  *Tests:* `spec/models/feature_intent_design_pr_spec.rb`,
  `spec/services/feature_intents/approval_readiness_spec.rb`.
  *Code:* `app/models/feature_intent_design_pr.rb`.

## Approval recording

- [x] **FEATURE-APPROVAL-004** — `FeatureIntent#record_approval!` SHALL
  transition the feature from `design_open`, `needs_decision`,
  `ready_for_approval`, or (to support refreshing a stale approval)
  `approved_waiting_for_merge` into `approved_waiting_for_merge`, and SHALL
  raise `FeatureIntent::InvalidTransitionError` from any other status
  (`released`, `revising`, `cancelled`, `discovering`).
  *Tests:* `spec/models/feature_intent_spec.rb`.
  *Code:* `app/models/feature_intent.rb`.

- [x] **FEATURE-APPROVAL-005** — Recording an approval SHALL persist the
  approving user (`approved_by`), the timestamp (`approved_at`), and a
  snapshot of every linked design PR's exact head SHA at approval time
  (`approved_pr_heads`, keyed by PR number) — "approve the exact revision,"
  not a PR number alone.
  *Tests:* `spec/models/feature_intent_spec.rb`,
  `spec/services/feature_intents/mark_approved_spec.rb`.
  *Code:* `app/models/feature_intent.rb#record_approval!`.

## Readiness gate

- [x] **FEATURE-APPROVAL-006** — `FeatureIntents::ApprovalReadiness` SHALL
  report the feature intent not ready, with one blocker per failing check,
  when: any linked question is unresolved; any inferred decision is
  unconfirmed; any *required* design PR is stale
  (`FEATURE-APPROVAL-003`); or the cached acceptance-criteria clarity
  verdict (`criteria_clarity_state`) is not `clear`. The clarity verdict
  itself is an AI judgment (ZFC — `FeatureIntents::CriteriaClarityReview`,
  citing only trusted linked issues) computed out-of-band by
  `FeatureIntents::EvaluateCriteriaClarity`/`EvaluateCriteriaClarityJob` and
  cached on the record (AGD) so Inbox rendering never makes a live LLM call
  per entry; a never-evaluated (`pending`) or failed review fails closed as
  blocking, matching the RDR-066 rule that a structurally complete RDR is
  not necessarily decision-ready.
  *Tests:* `spec/services/feature_intents/approval_readiness_spec.rb`,
  `spec/services/feature_intents/criteria_clarity_review_spec.rb`,
  `spec/services/feature_intents/evaluate_criteria_clarity_spec.rb`.
  *Code:* `app/services/feature_intents/approval_readiness.rb`,
  `app/services/feature_intents/criteria_clarity_review.rb`,
  `app/services/feature_intents/evaluate_criteria_clarity.rb`,
  `app/jobs/feature_intents/evaluate_criteria_clarity_job.rb`.

## Authorization

- [x] **FEATURE-APPROVAL-007** — `FeatureIntents::MarkApproved` SHALL be the
  single choke point for recording an approval: it SHALL check
  `FeatureIntentPolicy#approve?` (any account owner/admin/member, or a
  narrower-role account user — e.g. a `viewer` — holding an explicit
  project role, mirroring `ProjectPolicy#manage_issues?`) and SHALL raise
  `NotAuthorizedError` for anyone else, then SHALL check
  `FeatureIntents::ApprovalReadiness` and SHALL raise `NotReadyError`
  (carrying the blockers) when not ready, before calling
  `FeatureIntent#record_approval!`. Both the Inbox action and any future
  direct-GitHub-merge reconciliation call through this same service, so "a
  direct human merge counts only after readiness and authorized-actor
  checks" (RDR-066) and the Inbox action never disagree on who can approve.
  `FeatureIntentsController#approve` additionally calls Pundit's `authorize`
  before invoking the service.
  *Tests:* `spec/services/feature_intents/mark_approved_spec.rb`,
  `spec/policies/feature_intent_policy_spec.rb`,
  `spec/requests/feature_intents_spec.rb`.
  *Code:* `app/services/feature_intents/mark_approved.rb`,
  `app/policies/feature_intent_policy.rb`,
  `app/controllers/feature_intents_controller.rb`.

## Inbox surface

- [x] **FEATURE-APPROVAL-008** — `Inbox::Queue` SHALL expose a
  `feature_decision` entry for every `FeatureIntent` whose status is not
  `released`, `revising`, or `cancelled` (including `approved_waiting_for_merge`,
  since a stale head after approval reopens the hold). Unlike every other
  Inbox kind, these entries SHALL use project-membership visibility
  (`FeatureIntentPolicy::Scope`, the same pattern as `plan_review_entries`)
  rather than the auto-pick-gated `scoped_projects` used by
  `INBOX-FOUNDATION-006`, so a feature-design decision stays visible and
  actionable to any project member with Inbox access even on a planning
  project with auto-pick off. `Inbox::FeatureDecisionSummary` SHALL state
  either "Ready for approval.", the held blockers' messages (prefixed
  "Held:"), or, once approved, who approved it and that it is waiting to
  merge — so the Inbox always explains what keeps a feature held and what
  clears it. `Inbox::Count`'s badge SHALL include the same scope so the
  unread-style count and the queue agree.
  *Tests:* `spec/services/inbox/queue_spec.rb`,
  `spec/services/inbox/feature_decision_summary_spec.rb`,
  `spec/services/inbox/count_spec.rb`.
  *Code:* `app/services/inbox/queue.rb`,
  `app/services/inbox/feature_decision_summary.rb`,
  `app/services/inbox/count.rb`,
  `app/views/dashboard/_inbox_detail_feature_decision.html.erb`.
