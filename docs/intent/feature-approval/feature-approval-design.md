---
parent: PAID
prefix: FEATURE-APPROVAL
---

# Low-Level Design: Feature Approval

## Policy scope

This document defines the **approval-gated** feature policy. Its whole-feature
approval, amendment holds and latest-approved-revision rules do not govern
features explicitly enrolled in the planned [confidence-driven policy](../../rdrs/RDR-071-confidence-driven-issue-delivery.md).
Those features use issue-level readiness and completion-blocking follow-ups;
existing features retain their policy until deliberately migrated. Shared
record types and ordinary CI/security/quality checks remain reusable.

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the human-led feature operating mode from
> [RDR-066](../../rdrs/RDR-066-feature-intent-approval-lifecycle.md) in two
> slices: the named project setting, its configuration profile, and the
> onboarding posture proposal (#3872); and the Inbox decision flow and
> "Mark approved" action (#3864), which extends the minimal `FeatureIntent`
> substrate (`docs/intent/approved-intent-amendment/`, built for RDR-067)
> with the open-decision, design-PR, readiness, and approval-authorization
> machinery RDR-066's own approval lifecycle needs.

## Purpose

RDR-066 shifts human attention to discovery, design, and decisions: once a
human approves a complete feature design, Paid may execute the whole feature
tree within that approved scope. The operating mode is the posture switch
that makes a project run that workflow for new features. The Inbox — Paid's
existing typed queue of things needing a human — is the surface that shows
that approval decision and records it. Repository documents (the RDR PR, LID
Planning PR) remain the source of design content; this segment persists only
the linkage, open-decision state, and authorization record needed to enforce
the workflow.

## Operating mode, profile, and onboarding

### Operating-mode setting

- `projects.operating_mode` enum: `standard` (default) or
  `human_led_feature_factory` (`Project::OPERATING_MODES`).
- The column is the RDR-066 rollout-guard **config gate**: it ships default
  `standard`, so existing projects are never silently enrolled and nothing
  is paused on migration. No Flipper flag is involved — the guard is the
  named setting itself, exactly as the RDR's Rollout Guard specifies.
- The mode is a posture lever in the RDR-044 configuration-profile field
  set (`operating_mode` and `tdd_mode` descriptors), so the drift guards
  require every profile to declare an explicit value and existing profiles
  declare `standard` (opt-in only).
- Configuration profiles do not target tenant-level agent auto-continue.
  It is core iteration mechanics controlled explicitly at the tenant level,
  not a feature-approval or project-operating-mode choice.
- Every pre-existing profile targets `tdd_mode: "off"` for the same reason
  it targets `operating_mode: "standard"` — the field-set drift guard
  (`described_class.targets.keys` must match `profile_target_keys` exactly)
  forces a value once the descriptor exists. Re-applying one of those
  profiles to a project that already chose `non_strict`/`strict` TDD *does*
  plan a reset to `off` by default. Each legacy profile also declares
  `tdd_mode` as a clarifying question (`Base::TDD_MODE_CLARIFYING_QUESTION`),
  so a caller can pass `overrides: { "tdd_mode" => "strict" }` to keep the
  project's existing choice instead — the reset is the profile's suggested
  default, not a forced value, mirroring how `auto_merge_mode` already
  works.

### Named profile

- `Configuration::Profiles::HumanLedFeatureFactory` is registered in the
  curated registry and targets `operating_mode:
  "human_led_feature_factory"`.
- Suggested test-review posture: `tdd_mode: "non_strict"`.
- Auto-merge stays `off` by default; the profile declares clarifying
  questions for `auto_merge_mode` and `tdd_mode` so the owner explicitly
  chooses both — auto-merge and strict human TDD remain independent
  selections, per RDR-066's operating-mode decision.

### Onboarding proposal

- The `configure_defaults` onboarding step proposes the
  `human_led_feature_factory` posture for the account's first project with
  a reviewable settings plan rendered from `Configuration::Profiles::Planner`
  (deterministic before/after diff) before any write executes.
- Applying happens only on explicit acceptance, through
  `Configuration::Profiles::Applier` (one audited
  `configuration_profile.applied` activity event), honoring the operator's
  auto-merge and TDD selections.
- Declining leaves the project on `standard` defaults.

### Disabling the mode

- Mode changes are settings-only writes. Disabling
  `human_led_feature_factory` (direct edit or applying another profile)
  never enqueues, releases, or mutates issue/run state — held feature work
  requires an explicit migration decision (RDR-066 rollback posture), and
  when the release hold ships it must keep honoring this boundary.

## Scope of the Inbox slice

In scope (#3864):

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

The attachment and admission slices originally owned by #3863 and #3865
shipped in #4113 and #4114. `AttachFromAgentRun` creates and links Feature
Intents, design PRs, and proposed issue trees; `RunAdmission` enforces the
hold at selection, creation, dequeue, and dispatch; and design-PR
reconciliation uses the same `MarkApproved` authorization/readiness contract.

FEATURE-APPROVAL-019 remains open: attachment records repository/API facts
today, but does not turn an agent run's explicitly emitted questions or
`[inferred]` decisions into `FeatureIntentDecision` rows. The Inbox therefore
shows the truthful empty decision state rather than fabricating one.

## Approval revisions and release

Every Mark approved decision creates an immutable `FeatureIntentApprovalRevision`.
The revision records the approving Inbox-authorized user, its timestamp, source,
and the exact PR-number-to-head-SHA snapshot. `feature_intents` retains the
current approval fields as a denormalized read model for Inbox and existing
consumers; it never replaces the historical revision. An `AccountActivityEvent`
records each approval and release transition, including the revision number and
the transition's source and target states.

`FeatureIntents::Release` is the sole initial-release transition. It locks the
feature, requires `approved_waiting_for_merge`, a current approval snapshot,
and every `required` design PR to be merged. It then records the supplied merged
repository revision and moves the feature to `released`. A new PR head after
approval means the snapshot is no longer current, so release fails closed until
a fresh authorized human approval is recorded. The #4114 admission wiring uses
this release state; it does not bypass this transition contract.

## Inbox decision flow and Mark approved

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
  segment owns that could change the verdict. Initial attachment leaves the
  verdict `pending`, so it must be evaluated out of band before approval.
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
(`FEATURE-APPROVAL-010`); a later commit moves `head_sha` past
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
trusting the caller, so the direct-GitHub-merge reconciliation path (#4114)
inherits the identical rule without
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

## Create-feature and LID-planning attachment (#3863)

The attachment slice connects a `create_feature` (or chained `lid_planning`)
run to the `FeatureIntent` it creates and later renders. The agent run that
opens the RDR PR also registers the design PR, links the issue tree, and
records discovery evidence on the FeatureIntent — so the Inbox decision entry
the human sees is populated with the real design PR (not a placeholder), the
real issue tree (not a label guess), and evidence that traces to the
repository.

### What "attach" means

`create_feature` and `lid_planning` runs call a single choke point,
`FeatureIntents::AttachFromAgentRun`, that runs after the run's docs-only
PR opens. The service is the single place that decides what is recorded,
under what keys, and from which run-supplied facts:

- The `FeatureIntent` itself is created when the feature run is queued
  (`create_feature_run_and_redirect` in the agent-runs controller), status
  `discovering`. The brief issue that the run files is linked to the
  feature intent via a `FeatureIntentIssue` so the Inbox detail view can
  show the brief surface alongside the design PR record.
- When the docs-only PR is opened, `AttachFromAgentRun` records a
  `FeatureIntentDesignPr` with `design_pr_kind: "rdr"` for `create_feature`
  and `design_pr_kind: "lid_planning"` for `lid_planning`. The PR number,
  head SHA, and `required` flag come from the GitHub API response, not
  from the agent's output.
- Implementation issues filed by the run are recorded via
  `FeatureIntentIssue` at creation time (or shortly after via
  `AttachFromAgentRun` syncing `cross_repo_issues`) so the Inbox detail
  view can list the proposed tree alongside the design PR.
- If the docs-only PR is closed unmerged (a human reviewer rejected the
  RDR/LID Planning PR), the run transitions the feature to `cancelled` and
  closes the `FeatureIntentIssue` rows it created so no runnable orphan
  issue remains — the acceptance criterion "Closing the design PR
  unmerged leaves no runnable orphan issue" (#3860 acceptance #3).

### Evidence grounding

The service records evidence that traces to the repository or the run's
own output, never invented human answers. Two grounded sources:

- The `created_issue_url` / `pull_request_url` / `cross_repo_issues`
  recorded on the `AgentRun` are the source of truth for what was actually
  filed and opened. The FeatureIntent mirrors those facts. This is what
  FEATURE-APPROVAL-018 ships today (design PR rows + linked issues).
- Any clarifying questions or AI-inferred decisions the run produced will
  eventually be recorded on the FeatureIntent's `FeatureIntentDecision`
  rows only when the run's output explicitly contains them — the run's
  summary is parsed, not assumed. Inferred decisions will be flagged with
  `[inferred]` in their prompt text so a human can confirm or reject them
  through the Inbox (FEATURE-APPROVAL-007). The service never fabricates
  a question that the run did not raise. This behavior is tracked by the
  open spec FEATURE-APPROVAL-019 and is not yet implemented: today
  `AttachFromAgentRun` does not parse the run summary, and the Inbox
  decision-listing sections render empty when no decisions were separately
  recorded.

### Branching by run goal

`AttachFromAgentRun` branches on the agent run's `goal`:

- `create_feature` → `design_pr_kind: "rdr"`, `required: true`. A LID-mode
  project also gets a `lid_planning` design PR recorded by the chained
  `lid_planning` run when it opens its docs-only PR.
- `lid_planning` → `design_pr_kind: "lid_planning"`, `required: true` for
  LID-mode projects (LID planning is required to merge before
  implementation), `required: false` for projects that opt into the
  feature workflow without LID.
- Any other goal: no-op (the FeatureIntent is not created by this run).

### Closed-unmerged reconciliation

The `pull_request` webhook handler (`api/github_webhooks_controller.rb`)
calls `AttachFromAgentRun#detach_on_close!` when the design PR's GitHub
state transitions to `closed` without a merge — the webhook is the
reconciliation surface because GitHub emits it whether or not a Paid run
is in flight. The service transitions the FeatureIntent to `cancelled`
(a hard cancel — not a soft hold — because the human reviewer rejected
the design) and closes every linked issue both on GitHub (via the
project's GitHub client, best-effort per issue) and locally, so a later
issue sync cannot flip a locally closed row back to runnable. The
acceptance criterion "Closing the design PR unmerged leaves no runnable
orphan issue" is enforced here; the cancellation lands in its own write
so one failing issue close cannot roll it back. PR reopening is not a
path: a rejected design PR requires a new RDR/LID Planning PR and a new
FeatureIntent.

### Status transitions during attachment

The service does not invent transitions the lifecycle guard rejects:

- Creating a `FeatureIntent` from a queued run moves the feature to
  `discovering` (the initial state). `discovering` features appear in the
  Inbox decision lane so the team can see discovery is in flight, but are
  not approvable (`APPROVABLE_STATUSES` excludes `discovering`).
- The first `AttachFromAgentRun` after the docs-only PR opens moves the
  feature to `design_open` (the PR exists, design review is now possible).
  Subsequent calls on the same run are no-ops on the design PR record (the
  PR already exists) but may still record additional linked issues.
- A successful criteria-clarity evaluation moves the feature to
  `needs_decision` (open decisions block approval) or `ready_for_approval`
  (clarity is `clear`, decisions resolved).
- `AttachFromAgentRun` never moves the feature past `needs_decision`; only
  the criteria-clarity job and human approvals drive transitions into
  `ready_for_approval` and beyond.

### Why a service, not controller/inline code

The same service is called from the `create_feature` run, the chained
`lid_planning` run, and (for closed-unmerged reconciliation) from the
`pull_request` webhook handler. Putting the wiring in one place means the
paths cannot disagree about what a FeatureIntent records; the #4114
reconciliation path calls the same service.

## Rollout guard

The `operating_mode` column is the RDR-066 config gate (see above): it ships
default `standard`, so no existing project is silently enrolled. The
`FeatureIntents::AttachFromAgentRun` service attaches runs to a
`FeatureIntent` for every project that runs `create_feature` (the
`operating_mode` setting governs whether a project's issues are *held*
until approval — enforced by #4114 — not whether a feature-intent record exists for a
discovered feature). Per the RDR-066 rollout guard, do not release held
issues or bypass readiness/authorization on any rollback — those checks live
in code (`ApprovalReadiness`, `FeatureIntentPolicy`), not behind a flag that
could be flipped off.

## What this is not

- **Not an auto-merge or TDD policy change.** The profile suggests a
  posture; the owner's explicit choices win, and other profiles keep
  `standard` mode with their existing automation posture.
- **Not an approval bypass.** The issue-tree hold/release and direct GitHub
  merge reconciliation enforce the same readiness and authorization contract
  through `FeatureIntents::RunAdmission` and `MarkApproved`; an approval does
  not independently make work runnable before the design is released.
