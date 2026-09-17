---
parent: PAID
prefix: FEATURE-APPROVAL
---

# Low-Level Design: Feature Approval (Inbox)

> Companion to the high-level design (`docs/high-level-design.md`). Implements
> the Inbox decision-flow and "Mark approved" slice of
> [RDR-066](../../rdrs/RDR-066-feature-intent-approval-lifecycle.md) (#3864),
> extending the minimal `FeatureIntent` substrate
> (`docs/intent/approved-intent-amendment/`, built for RDR-067) with the
> open-decision, design-PR, readiness, and approval-authorization machinery
> RDR-066's own approval lifecycle needs.

## Purpose

RDR-066 moves a project's implementation-authorization boundary from
per-issue judgment to a human-approved feature design: once a human approves
a complete design, Paid may execute the whole issue tree within that scope.
This segment gives the Inbox — Paid's existing typed queue of things needing
a human — the surface to show that decision and to record it. Repository
documents (the RDR PR, LID Planning PR) remain the source of design content;
this segment persists only the linkage, open-decision state, and
authorization record needed to enforce the workflow.

## Scope

In scope (this segment):

- `FeatureIntentDecision` — open clarifying questions and AI-inferred
  decisions, each bound to the design claim it affects.
- `FeatureIntentDesignPr` — linked design PRs (RDR, LID Planning) with head
  tracking and a `required` flag, so approval readiness can tell a stale or
  optional artifact from a blocking one.
- `FeatureIntents::ApprovalReadiness` — the deterministic + AI-assisted
  readiness gate: open questions, unconfirmed inferred decisions, stale
  required design PRs, and cached acceptance-criteria clarity.
- `FeatureIntents::CriteriaClarityReview` / `EvaluateCriteriaClarity` /
  `EvaluateCriteriaClarityJob` — the AI judgment on whether acceptance
  criteria are specific enough to separate an in-scope PR from drift,
  computed out-of-band and cached (AGD), never live during Inbox render.
- `FeatureIntent#record_approval!` and `FeatureIntents::MarkApproved` — the
  lifecycle transition and the single authorization+readiness choke point
  for recording an approval.
- `FeatureIntentPolicy` — "any project member with Inbox access" (broader
  than the admin-only pattern `PlanReviewPolicy` uses for plan reviews).
- The `feature_decision` Inbox entry kind, its project-membership scoping,
  `Inbox::FeatureDecisionSummary`'s held/cleared explanation, and the detail
  view with the Mark approved action.

Out of scope (owned by sibling issues under #3860): attaching `create_feature`
/`lid_planning` output (design PRs, proposed issue tree, generated
questions/evidence) to a `FeatureIntent` (#3863); enforcing the release hold
at auto-pick, eager queue, dequeue, and manual `create_pr` entry points, and
reconciling direct GitHub human merges, bot merges, and abandoned design PRs
against this same readiness/authorization contract (#3865); the named
`human_led_feature_factory` operating mode and onboarding default (#3872).
Until #3863 lands, no code path creates `FeatureIntentDecision` or
`FeatureIntentDesignPr` rows outside tests, so this segment's behavior is
present but dormant for existing projects — no rollout flag is needed for
that reason alone (see Rollout guard below).

## Design

### Readiness is a single answer, computed once

`FeatureIntents::ApprovalReadiness.call(feature_intent:)` returns a
`Result` (`ready?`, `blockers:` — an ordered list of `{code:, message:}`).
Every blocker is a deterministic read: the feature's status against
`FeatureIntent::APPROVABLE_STATUSES` (mirrors
`FeatureIntent#record_approval!`'s lifecycle guard so `discovering`
features that show in the Inbox are never presented as approvable), open
`FeatureIntentDecision` rows, stale *required* `FeatureIntentDesignPr` rows,
and the feature's cached `criteria_clarity_state`.
`Inbox::FeatureDecisionSummary`, the detail view, and
`FeatureIntents::MarkApproved` all call this same service, so the Inbox
list, the Inbox detail pane, and the action that actually records an
approval can never disagree about whether "Mark approved" should be
available — the RDR-066 acceptance criterion "Mark approved is unavailable
with unresolved questions, unconfirmed inferred decisions, vague criteria,
or stale heads" is enforced in exactly one place.

### Acceptance-criteria clarity is AI-assisted but AGD-cached, not ZFC-per-render

Whether acceptance criteria are specific enough to separate an in-scope PR
from drift is a semantic judgment (ZFC: delegate to AI, not keyword
matching). But `ApprovalReadiness` runs once per Inbox render per visible
feature intent — calling an LLM synchronously there would mean one live
model round-trip per entry per page view, an unacceptable latency and cost
regression (AGD: use AI once, cache a deterministic artifact). So the split
is:

- `FeatureIntents::CriteriaClarityReview` makes the actual judgment
  (`clear:`, `confidence:`, `explanation:`), following the same
  structural-validation-only pattern as `DesignAmendments::ImpactReview`:
  confidence floor, only trusted linked issues in the prompt, any failure
  mode returns `nil`.
- `FeatureIntents::EvaluateCriteriaClarity` runs the review and persists the
  verdict onto `feature_intents.criteria_clarity_state` (`pending` / `clear`
  / `vague`) plus an explanation and timestamp. A `nil` review (failure)
  fails closed to `vague`.
- `FeatureIntents::EvaluateCriteriaClarityJob` is the background entry
  point. `FeatureIntentDecision#resolve!` enqueues it — resolving a question
  or confirming an inferred decision is the one control-flow event this
  segment owns that could change the verdict. `#3863` is expected to
  enqueue it too, whenever it changes a feature's brief or linked issues.
- `ApprovalReadiness` reads only the cached column. A feature intent that
  has never been evaluated (`pending`) blocks, same as an explicit `vague`
  verdict — "do not equate a structurally complete RDR with a
  decision-ready RDR" applies to Paid's own unevaluated state too.

### Design PR staleness: two related but distinct signals

RDR-066 names two edge cases that read similarly but are not the same
check. `FeatureIntentDesignPr` tracks both:

- `head_sha` — the PR's most recently synced head.
- `reviewed_head_sha` — the head the feature's current open decisions and
  evidence were generated against.

`stale?` is `head_sha != reviewed_head_sha` (when a review has happened at
all). Before a first approval, this blocks the *first* Mark approved click
until Paid re-evaluates a PR that moved after discovery ran. After an
approval, `approved_pr_heads` already recorded the exact reviewed heads
(`FEATURE-APPROVAL-005`); a later commit moves `head_sha` past
`reviewed_head_sha` again, which both invalidates the stale approval (the
feature is no longer meaningfully "approved" — see
`Inbox::FeatureDecisionSummary`) and blocks a naive re-approval attempt
until discovery catches up to the new head. Only `required: true` design
PRs participate — an optional artifact (per the project's LID mode) going
stale does not hold the feature.

### Authorization: broader than plan-review, still project-scoped

`PlanReviewPolicy#manage?` delegates to `ProjectPolicy#update?`
(owner/admin only) because approving a decomposition plan is a project
configuration decision. RDR-066 is explicit that feature-design approval is
different: "Any project member with Inbox access may approve." So
`FeatureIntentPolicy#approve?` delegates to `ProjectPolicy#manage_issues?`
instead — true for any account owner/admin/member automatically, and for a
narrower-role account user (e.g. an account `viewer`) who holds an explicit
project role. It is never true across accounts: `ProjectPolicy#manage_issues?`
gates on `user_in_account?` first, so a project-level role only grants a
same-account user broader access to one project, not a cross-account guest
grant (there is no such grant anywhere in this codebase to mirror).

`FeatureIntents::MarkApproved` re-checks authorization itself rather than
trusting the caller, specifically so a future direct-GitHub-merge
reconciliation path (#3865) inherits the identical rule without
re-implementing it — "GitHub merge permission alone must not silently widen
who can approve a Paid feature" (RDR-066). `FeatureIntentsController#approve`
also calls Pundit's `authorize` up front (repository convention, and what
drives the standard "not authorized" flash/redirect), so the check runs
twice on the Inbox path by design: once for the controller's own
Pundit bookkeeping, once inside the service as the invariant that holds
regardless of caller.

### Inbox scoping deliberately diverges from every other kind

Every existing Inbox kind (`INBOX-FOUNDATION-006`) scopes to the user's
*auto-pick-enabled* projects. RDR-066 explicitly requires feature-decision
entries to stay visible on a planning project with auto-pick off — the
whole point of the mode is that implementation is gated on approval, not on
auto-pick being on. `feature_decision_entries` therefore uses
`FeatureIntentPolicy::Scope` (a `ProjectPolicy::Scope` merge, the same
project-membership pattern `plan_review_entries` already uses) instead of
`scoped_projects`. `Inbox::Count`'s badge mirrors the same scope so the
queue and the unread-style count never disagree about what a user can see.

## Persistence

- `feature_intents` — extended with `approved_by_id`, `approved_at`,
  `approved_pr_heads` (jsonb snapshot), and `criteria_clarity_state` /
  `criteria_clarity_explanation` / `criteria_clarity_evaluated_at`.
- `feature_intent_decisions` — open questions and inferred decisions, each
  naming the design claim it affects; resolution records actor and time.
- `feature_intent_design_prs` — linked design PRs with `head_sha` /
  `reviewed_head_sha` staleness tracking, `required`, and `merged_at`.

Actor and transition audit live on the records themselves (`approved_by`,
`approved_at`, `resolved_by`, `resolved_at`); no logidze on these
operational, high-churn-during-discovery tables.

## Rollout guard

No new feature flag: nothing in the application creates a `FeatureIntent`,
`FeatureIntentDecision`, or `FeatureIntentDesignPr` row outside tests until
`#3863` wires `create_feature`/`lid_planning` to this substrate, so this
segment's Inbox entries and Mark approved action are structurally inert for
every existing project today. When `#3863` lands, the named
`human_led_feature_factory` operating mode (`#3872`) is the actual rollout
gate for *creating* feature intents in the first place; this segment does
not duplicate that gate. Per the RDR-066 rollout guard, do not release held
issues or bypass readiness/authorization on any rollback — those checks live
in code (`ApprovalReadiness`, `FeatureIntentPolicy`), not behind a flag that
could be flipped off.
