# EARS Specs: Approved Intent Conformance (PR scanner + Inbox surface)

> Testable claims for issue #3867's scope of RDR-067: PR-scanner blocker
> integration and the typed Inbox decision. Status markers: `[x]` implemented
> · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r INTENT-CONFORMANCE-001`).

- [x] **INTENT-CONFORMANCE-001** — When a lookup requests the current intent
  conformance verdict for an issue and PR HEAD SHA, the system SHALL return
  the most recently evaluated `IntentConformanceVerdict` row matching that
  exact `(issue, pr_head_sha)` pair, and SHALL return no verdict for any other
  HEAD, so a new commit always invalidates the prior verdict.
  *Code:* `app/models/intent_conformance_verdict.rb`.
  *Test:* `spec/models/intent_conformance_verdict_spec.rb`.

- [x] **INTENT-CONFORMANCE-002** — When the `intent_conformance_enforcement`
  feature flag is disabled for a project, or the PR HEAD SHA is unknown, the
  system SHALL treat the `intent_conformance_ok` signal as satisfied, so
  projects that have not opted into conformance enforcement are unaffected.
  *Code:* `app/services/intent_conformance/signal.rb`.
  *Test:* `spec/services/intent_conformance/signal_spec.rb`.

- [x] **INTENT-CONFORMANCE-003** — When conformance enforcement is on for a
  project and a PR's current HEAD has no `within_scope` verdict — because the
  verdict outcome is `material_drift`, `uncertain`, `not_evaluated`, or no
  verdict exists for that HEAD — the system SHALL treat `intent_conformance_ok`
  as unsatisfied unless a `bounded_exception` decision exists for that exact
  HEAD, blocking auto-merge through the existing `AutoMerge` blocker gate.
  *Code:* `app/services/intent_conformance/signal.rb`,
  `app/services/automation/strategies/auto_merge.rb`,
  `app/services/automation/strategies/auto_merge/signals.rb`.
  *Test:* `spec/services/intent_conformance/signal_spec.rb`,
  `spec/services/automation/strategies/auto_merge_spec.rb`.

- [x] **INTENT-CONFORMANCE-004** — When a human resolves a blocked intent
  conformance verdict, the system SHALL record an `IntentConformanceDecision`
  with the actor, the action (`fix_pr`, `bounded_exception`, or
  `design_amendment`), the PR HEAD SHA the decision applies to, and the
  actor-supplied reason, and SHALL reject the decision when the reason is
  blank or the action is not one of the three defined actions.
  *Code:* `app/services/intent_conformance/record_decision.rb`,
  `app/models/intent_conformance_decision.rb`,
  `app/controllers/projects/intent_conformance_decisions_controller.rb`.
  *Test:* `spec/services/intent_conformance/record_decision_spec.rb`,
  `spec/requests/projects/intent_conformance_decisions_spec.rb`.

- [x] **INTENT-CONFORMANCE-005** — When a `bounded_exception` decision exists
  for an issue, the system SHALL treat it as active only while the PR's
  current HEAD SHA still matches the decision's recorded `head_sha`; once a
  new commit changes the HEAD, the exception SHALL no longer satisfy
  `intent_conformance_ok`, so a later, unreviewed change is never silently
  covered by an earlier exception.
  *Code:* `app/models/intent_conformance_decision.rb`,
  `app/services/intent_conformance/signal.rb`.
  *Test:* `spec/models/intent_conformance_decision_spec.rb`,
  `spec/services/intent_conformance/signal_spec.rb`.

- [x] **INTENT-CONFORMANCE-006** — When an open, ready-phase pull request's
  persisted auto-merge blocker snapshot includes a failed
  `intent_conformance_ok` signal, the system SHALL expose that pull request as
  an `intent_conformance` inbox entry showing the verdict's cited design
  claims, cited diff locations, reasoning summary, outcome, and the most
  recent human decision if one exists, distinct from the `merge_approval` lane
  (the `intent_conformance_ok` signal is excluded from
  `Inbox::MergeApproval::APPROVAL_SIGNALS`), until a fresh `within_scope`
  verdict, a matching bounded exception, or a merge/close outcome clears it.
  *Code:* `app/services/inbox/intent_conformance.rb`,
  `app/services/inbox/queue.rb`, `app/services/inbox/count.rb`,
  `app/views/dashboard/_inbox_detail_intent_conformance.html.erb`.
  *Test:* `spec/services/inbox/intent_conformance_spec.rb`,
  `spec/services/inbox/queue_spec.rb`, `spec/requests/inbox_spec.rb`.

- [x] **INTENT-CONFORMANCE-007** — When the PR scanner evaluates a
  human-authored pull request's auto-merge signals, the system SHALL compute
  the `intent_conformance_ok` signal from the PR's live HEAD SHA and persist
  that HEAD SHA to `issues.last_scanned_head_sha` in the same scan pass that
  persists the blocker snapshot, so downstream consumers (the Inbox lane, a
  future final-merge check) can identify the scanned HEAD without an extra
  GitHub call. A pass that stages nothing SHALL preserve the previously
  persisted HEAD SHA rather than wipe it, and a new HEAD SHALL overwrite the
  stored value.
  *Code:* `app/temporal/activities/scan_paid_prs_activity.rb`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.

- [x] **INTENT-CONFORMANCE-008** — When intent-conformance verdicts or
  decisions are read or written, the system SHALL enforce forced tenant
  row-level security on both tables, keying rows through
  `issues → projects.account_id = paid_current_account_id()` (and, for
  decisions, additionally requiring the actor user's
  `users.account_id` to match), so no account can observe or mutate another
  account's verdicts or decisions.
  *Code:* `db/migrate/20260917040153_enable_rls_on_intent_conformance_tables.rb`.
  *Test:* `spec/migrations/create_intent_conformance_verdicts_spec.rb`.

- [x] **INTENT-CONFORMANCE-009** — When a pull request's failed
  `intent_conformance_ok` signal is the only remaining condition keeping it
  out of auto-merge alongside owner approval, the system SHALL NOT classify
  the pull request as blocked only on approval (so it never starts the
  approval-wait clock, escalates to `awaiting_approval`, or pings the owner
  for an approval that cannot clear the merge) until the conformance signal
  is satisfied again.
  *Code:* `app/temporal/activities/scan_paid_prs_activity.rb`,
  `app/services/pull_requests/blocked_only_on_approval.rb`.
  *Test:* `spec/temporal/activities/scan_paid_prs_activity_spec.rb`,
  `spec/services/pull_requests/blocked_only_on_approval_spec.rb`.
