# EARS Specs: Feature Approval

> Testable claims for the human-led feature operating mode from
> [RDR-066](../../rdrs/RDR-066-feature-intent-approval-lifecycle.md):
> the named profile and onboarding posture (#3872, `001`–`005`) and the
> feature-design decision flow and "Mark approved" action surfaced through
> the existing typed Inbox (#3864, `006`–`013`; see
> `docs/intent/inbox-foundation/`, `docs/intent/operator-inbox/`).
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r FEATURE-APPROVAL-001`).

## Operating mode and onboarding

- [x] **FEATURE-APPROVAL-001** — When the human-led feature operating mode
  ships, the `operating_mode` column SHALL default to `standard` and reject
  unknown values, so no existing project is silently enrolled and new
  projects start unenrolled unless the mode is deliberately chosen.

- [x] **FEATURE-APPROVAL-002** — When the `human_led_feature_factory`
  configuration profile is applied, the project SHALL enter the human-led
  feature operating mode with `non_strict` TDD as the suggested
  test-review posture, and `auto_merge_mode` SHALL remain `off` unless the
  operator explicitly selects otherwise.

- [x] **FEATURE-APPROVAL-003** — When an operator adopts the profile with
  explicit auto-merge or TDD selections, the system SHALL apply those
  selections instead of the suggested defaults, so auto-merge and strict
  human test review remain independent project choices.

- [x] **FEATURE-APPROVAL-004** — When a new account reaches the
  configure-defaults onboarding step with a first project, onboarding SHALL
  propose the `human_led_feature_factory` posture with a reviewable
  settings plan and SHALL apply it only after the user accepts the
  proposal.

- [x] **FEATURE-APPROVAL-005** — When a project leaves the
  `human_led_feature_factory` operating mode, the system SHALL NOT release,
  enqueue, or otherwise mutate issue or run state; disabling the mode is a
  settings-only change and any held work stays held until explicitly
  migrated.

## Open decisions

- [x] **FEATURE-APPROVAL-006** — For approval-gated features, a `FeatureIntentDecision` of kind
  `question` SHALL record the prompt text and the design claim it affects,
  and SHALL stay `open` until a human resolves it with an answer, actor, and
  timestamp.
  *Tests:* `spec/models/feature_intent_decision_spec.rb`.
  *Code:* `app/models/feature_intent_decision.rb`.

- [x] **FEATURE-APPROVAL-007** — For approval-gated features, a `FeatureIntentDecision` of kind
  `inferred_decision` SHALL represent an AI-inferred assumption that requires
  explicit human confirmation before it counts as resolved; resolving it
  SHALL use the same `resolve!` path as a question.
  *Tests:* `spec/models/feature_intent_decision_spec.rb`.
  *Code:* `app/models/feature_intent_decision.rb`.

## Design PR tracking and staleness

- [x] **FEATURE-APPROVAL-008** — For approval-gated features, a `FeatureIntentDesignPr` SHALL track a
  linked design pull request's `head_sha` alongside a `reviewed_head_sha` —
  the head its open decisions/evidence were last generated against — and
  SHALL report `stale?` when the two diverge, so a commit landing after
  discovery is never silently approved on stale evidence. Only PRs where
  `required: true` block readiness; optional artifacts going stale does not.
  *Tests:* `spec/models/feature_intent_design_pr_spec.rb`,
  `spec/services/feature_intents/approval_readiness_spec.rb`.
  *Code:* `app/models/feature_intent_design_pr.rb`.

## Approval recording

- [x] **FEATURE-APPROVAL-009** — For approval-gated features, `FeatureIntent#record_approval!` SHALL
  transition the feature from `design_open`, `needs_decision`,
  `ready_for_approval`, or (to support refreshing a stale approval)
  `approved_waiting_for_merge` into `approved_waiting_for_merge`, and SHALL
  raise `FeatureIntent::InvalidTransitionError` from any other status
  (`released`, `revising`, `cancelled`, `discovering`).
  *Tests:* `spec/models/feature_intent_spec.rb`.
  *Code:* `app/models/feature_intent.rb`.

- [x] **FEATURE-APPROVAL-010** — For approval-gated features, recording an approval SHALL persist the
  approving user (`approved_by`), the timestamp (`approved_at`), and a
  snapshot of every linked design PR's exact head SHA at approval time
  (`approved_pr_heads`, keyed by PR number) — "approve the exact revision,"
  not a PR number alone.
  *Tests:* `spec/models/feature_intent_spec.rb`,
  `spec/services/feature_intents/mark_approved_spec.rb`.
  *Code:* `app/models/feature_intent.rb#record_approval!`.

## Readiness gate

- [x] **FEATURE-APPROVAL-011** — For approval-gated features, `FeatureIntents::ApprovalReadiness` SHALL
  report the feature intent not ready, with one blocker per failing check,
  when: the feature's `status` is not in `FeatureIntent::APPROVABLE_STATUSES`
  (mirrors `FeatureIntent#record_approval!`'s lifecycle guard so the Inbox
  entry, the detail view, and `MarkApproved` never disagree on which
  statuses accept an approval — `discovering` features show in the Inbox
  but are not approvable); any linked question is unresolved; any inferred
  decision is unconfirmed; any *required* design PR is stale
  (`FEATURE-APPROVAL-008`); or the cached acceptance-criteria clarity
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

- [x] **FEATURE-APPROVAL-012** — For approval-gated features, `FeatureIntents::MarkApproved` SHALL be the
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
  before invoking the service, and SHALL rescue
  `FeatureIntent::InvalidTransitionError` (defense in depth — readiness
  reports the same status rule, but a status change between render and
  action, or a caller bypassing the Inbox UI, can still surface it) into
  the same graceful "not ready" redirect the other rejection paths use.
  *Tests:* `spec/services/feature_intents/mark_approved_spec.rb`,
  `spec/policies/feature_intent_policy_spec.rb`,
  `spec/requests/feature_intents_spec.rb`.
  *Code:* `app/services/feature_intents/mark_approved.rb`,
  `app/policies/feature_intent_policy.rb`,
  `app/controllers/feature_intents_controller.rb`.

## Inbox surface

- [x] **FEATURE-APPROVAL-013** — For approval-gated features, `Inbox::Queue` SHALL expose a
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
  unread-style count and the queue agree. The Inbox nav filter
  (`app/views/inbox/index.html.erb`) SHALL offer a `feature_decision` tab
  alongside the other kinds, and the empty-state copy SHALL name every lane
  kind the queue exposes (#3908).
  *Tests:* `spec/services/inbox/queue_spec.rb`,
  `spec/services/inbox/feature_decision_summary_spec.rb`,
  `spec/services/inbox/count_spec.rb`.
  *Code:* `app/services/inbox/queue.rb`,
  `app/services/inbox/feature_decision_summary.rb`,
  `app/services/inbox/count.rb`,
  `app/views/inbox/index.html.erb`,
  `app/views/dashboard/_inbox_detail_feature_decision.html.erb`.

## Create-feature and LID-planning attachment (#3863)

- [x] **FEATURE-APPROVAL-014** — For approval-gated features, when a
  `create_feature` agent run is queued, the system SHALL create a
  `FeatureIntent` linked to that run's brief issue (`status: "discovering"`,
  `criteria_clarity_state: "pending"`), and the brief issue SHALL be linked
  back to the feature via a `FeatureIntentIssue` so the Inbox detail view
  can show the brief alongside the design PR record. The system SHALL use
  one choke point (`FeatureIntents::AttachFromAgentRun`) for both
  `create_feature` and `lid_planning` runs, so neither path can disagree
  about what a FeatureIntent records.
  *Tests:* `spec/services/feature_intents/attach_from_agent_run_spec.rb`,
  `spec/requests/projects/agent_runs_create_feature_spec.rb`.
  *Code:* `app/services/feature_intents/attach_from_agent_run.rb`,
  `app/controllers/projects/agent_runs_controller.rb`.

- [x] **FEATURE-APPROVAL-015** — For approval-gated features, when a
  `create_feature` agent run opens its docs-only RDR PR, the system SHALL
  record a `FeatureIntentDesignPr` with `design_pr_kind: "rdr"`,
  `required: true`, the PR number and head SHA read from the GitHub API
  response (not from the agent's output), and `reviewed_head_sha` set to
  the same head SHA so the staleness signal starts consistent. A chained
  `lid_planning` run SHALL record a second design PR with
  `design_pr_kind: "lid_planning"`, `required: true` for LID-mode projects
  and `required: false` otherwise. A second `AttachFromAgentRun` call on
  the same PR SHALL NOT duplicate the design PR record (uniqueness by
  `(feature_intent_id, pull_request_number)`).
  *Tests:* `spec/services/feature_intents/attach_from_agent_run_spec.rb`.
  *Code:* `app/services/feature_intents/attach_from_agent_run.rb`,
  `app/temporal/activities/create_pull_request_activity.rb`.

- [x] **FEATURE-APPROVAL-016** — For approval-gated features, every
  implementation issue filed by a `create_feature` (or chained
  `lid_planning`) run SHALL be linked to its `FeatureIntent` via a
  `FeatureIntentIssue` row at creation time (when the run records it in
  `cross_repo_issues`) so the Inbox detail view's "Proposed issue tree"
  section lists the real filed issues alongside the design PR. The link
  SHALL NOT depend on a label or auto-pick status — the
  `FeatureIntentIssue` row is the source of truth.
  *Tests:* `spec/services/feature_intents/attach_from_agent_run_spec.rb`,
  `spec/temporal/activities/create_pull_request_activity_spec.rb`.
  *Code:* `app/services/feature_intents/attach_from_agent_run.rb`,
  `app/temporal/activities/create_pull_request_activity.rb`.

- [x] **FEATURE-APPROVAL-017** — For approval-gated features, when a
  design PR (RDR or LID Planning) linked to a `FeatureIntent` is closed
  unmerged on GitHub, the system SHALL transition the feature to
  `cancelled` and SHALL close every linked issue — on GitHub and in
  Paid's database — so no runnable orphan issue remains (RDR-066
  acceptance criterion #3: "Closing the design PR unmerged leaves no
  runnable orphan issue"; closing upstream prevents the next issue sync
  from flipping a locally closed row back to runnable). The close SHALL
  be applied through `AttachFromAgentRun#detach_on_close!`, called from
  the `pull_request` webhook handler on the closed-unmerged event
  (`api/github_webhooks_controller.rb`) — the webhook is the
  reconciliation surface because GitHub emits it whether or not a Paid
  run is in flight. The cancellation lands in its own write and each
  per-issue close is best-effort, so one failing issue row cannot roll
  back the cancellation or block the remaining closes. A subsequent
  GitHub-side reopen of the same PR SHALL NOT resurrect the feature — a
  rejected design PR requires a new RDR and a new `FeatureIntent`.
  *Tests:* `spec/services/feature_intents/attach_from_agent_run_spec.rb`,
  `spec/requests/api/github_webhooks_spec.rb`.
  *Code:* `app/services/feature_intents/attach_from_agent_run.rb`,
  `app/controllers/api/github_webhooks_controller.rb`.

- [x] **FEATURE-APPROVAL-018** — For approval-gated features, evidence
  recorded on the `FeatureIntent` for design PRs and linked issues SHALL
  be grounded in the repository or the run's own output, not in human
  answers Paid invented. The `FeatureIntentDesignPr` row's
  `pull_request_number` and `head_sha` come from the GitHub API response
  on the docs-only PR opening, not from the agent summary.
  `FeatureIntentIssue` rows come from the `cross_repo_issues` the run
  recorded against the issue it actually filed on GitHub. (Decision
  recording — the `FeatureIntentDecision` grounding claim — is tracked
  separately in FEATURE-APPROVAL-019; this spec is scoped to the
  design-PR/issue-link evidence the attach service ships.)
  *Tests:* `spec/services/feature_intents/attach_from_agent_run_spec.rb`.
  *Code:* `app/services/feature_intents/attach_from_agent_run.rb`.

- [ ] **FEATURE-APPROVAL-019** — For approval-gated features, the run
  path SHALL record `FeatureIntentDecision` rows on the `FeatureIntent`
  only when the run's own summary explicitly contains the question or
  the `[inferred]` decision; absent decisions SHALL surface as the
  truthful "no questions" state in the Inbox detail view, not a
  fabricated default. Currently the design-doc section "Evidence grounding"
  describes this behavior but the recording code path does not ship
  (`FeatureIntents::AttachFromAgentRun` does not parse the run summary
  for questions/inferred decisions); the Inbox decision-listing section
  is therefore still empty for every project. This spec is the gap
  marker — code/tests land in the follow-up that implements the
  decision-recording path.
  *Tests:* (none — pending implementation).
  *Code:* (none — pending implementation; tracks alongside
  `app/services/feature_intents/attach_from_agent_run.rb`).

## Immutable approval and release

- [x] **FEATURE-APPROVAL-020** — When an Inbox-authorized human approves a
  ready feature intent, the system SHALL append an immutable approval revision
  containing the actor, timestamp, source, and exact linked design-PR head
  snapshot. Re-approval after a changed head SHALL append, rather than mutate,
  the earlier revision.

- [x] **FEATURE-APPROVAL-021** — When releasing an approval-gated feature,
  the system SHALL reject the transition unless the feature is awaiting merge,
  its latest approval snapshot still equals every linked design PR head, and
  every required design PR is merged. On success it SHALL record the merged
  repository revision and transition the feature to `released`.

- [x] **FEATURE-APPROVAL-022** — When an approval or release transition is
  recorded, the system SHALL append an account activity audit event naming the
  actor when known, feature intent, transition source and target, and approval
  revision when applicable.

## Release admission (#3865)

- [x] **FEATURE-APPROVAL-023** — When an issue is linked to a feature intent
  that is not released, the system SHALL fail closed at automatic selection,
  eager seeding, dequeue, manual creation, and immediately before workflow
  dispatch. A queued run that becomes held SHALL be cancelled before it starts.
  *Tests:* `spec/services/feature_intents/run_admission_spec.rb`,
  `spec/services/agent_runs/recheck_issue_eligibility_spec.rb`.
  *Code:* `app/services/feature_intents/run_admission.rb`,
  `app/services/automation/strategies/auto_pick/default_candidate_source.rb`,
  `app/services/agent_runs/recheck_issue_eligibility.rb`,
  `app/jobs/process_run_queue_job.rb`, `app/models/agent_run.rb`.

- [x] **FEATURE-APPROVAL-024** — When a feature intent is released, every
  newly admitted implementation run SHALL snapshot its `approved_design_revision`,
  and the repository checkout SHALL create its branch at that exact revision.
  Dispatch SHALL cancel a queued run if its revision no longer matches the
  feature's current released revision.
  *Tests:* `spec/services/feature_intents/run_admission_spec.rb`,
  `spec/models/agent_run_spec.rb`, `spec/services/containers/git_operations_spec.rb`.
  *Code:* `app/services/feature_intents/run_admission.rb`, `app/models/agent_run.rb`,
  `app/services/containers/git_operations.rb`, `app/jobs/process_run_queue_job.rb`.

- [x] **FEATURE-APPROVAL-025** — When GitHub reconciliation observes a design
  merge, a complete direct human merge with a provider-verified identity SHALL
  call `FeatureIntents::MarkApproved` before release, so the same Paid
  membership and readiness checks apply as for Inbox approval. The feature
  SHALL release only if its current human approval matches every required
  design PR head, every required design PR has merged, and the reconciler
  supplies the resulting repository revision. An incomplete merge, stale
  approval, unverifiable merger, or bot merge without prior human approval
  SHALL remain held.
  *Tests:* `spec/services/feature_intents/release_spec.rb`,
  `spec/services/feature_intents/reconcile_design_pull_request_spec.rb`,
  `spec/temporal/activities/fetch_issues_activity_spec.rb`.
  *Code:* `app/services/feature_intents/reconcile_design_pull_request.rb`,
  `app/services/feature_intents/release.rb`, `app/services/issues/upsert_from_github.rb`,
  `app/temporal/activities/fetch_issues_activity.rb`,
  `app/models/feature_intent.rb`.
