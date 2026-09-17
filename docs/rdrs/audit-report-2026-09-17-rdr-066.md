# RDR-066 Closeout Audit

- **RDR**: [RDR-066](RDR-066-feature-intent-approval-lifecycle.md)
- **Audit date**: 2026-09-17
- **Closeout issue**: [#3873](https://github.com/viamin/paid/issues/3873)
- **Conclusion**: Partially Implemented

## Scope

Audit shipped code, tests, and docs against RDR-066 and umbrella issue #3860:
the Feature Intent record and lifecycle, discovery/approval readiness, approval
sources and revision binding, issue-tree hold and release enforcement, the
named `human_led_feature_factory` operating mode, and the rollout guard. This
follows the [RDR Closeout Checklist](closeout-checklist.md).

## Method

Searched the full working tree (`app/`, `spec/`, `lib/`, `config/`,
`db/schema.rb`, `docs/intent/`, `docs/arrows/index.yaml`) for the vocabulary
the RDR and its implementation plan introduce: `FeatureIntent`, `feature
intent`, the named lifecycle states (`design_open`, `needs_decision`,
`ready_for_approval`, `approved_waiting_for_merge`), `mark approved` /
`release_hold`, and the `human_led_feature_factory` profile key. Per the
checklist, a closed dependency issue is not treated as evidence — only merged
code and passing tests count.

## Shipped

RDR-066 itself is Final on main (design PR #3859, finalization PR #3874). The
prerequisite infrastructure it builds on has already shipped under other,
already-Implemented RDRs and remains available for the feature-approval
workflow to build on:

- Configuration profiles and the operating-mode field-set contract
  (RDR-044): `app/services/configuration_profiles/registry.rb`,
  `app/services/configuration/profiles/registry.rb`, and the existing profile
  set (`cost_capped_automated`, `manual_on_label`, `observe_only`,
  `quality_strict`, `solo_automated`, `team_reviewed` in
  `app/services/configuration/profiles/`).
- LID-aware Planning PRs and HLD/LLD/EARS conversion surface (RDR-051):
  `docs/intent/lid-aware-agent-runs/`.
- `create_feature` / `lid_planning` issue-tree and RDR-PR flow (RDR-053):
  `docs/intent/`, referenced by RDR-066 as the extension point.
- Strict/non-strict TDD mode as an independent per-project setting (RDR-056),
  confirmed already `Implemented` in `docs/rdrs/README.md:156`.
- `Inbox::Queue`'s typed entry composition (clarifying-question,
  plan-review, merge-approval, escalated-PR, manual-review) at
  `app/services/inbox/queue.rb`, which RDR-066 designates as the surface to
  extend rather than replace.
- `Automation::Strategies::AutoPick::DefaultCandidateSource` at
  `app/services/automation/strategies/auto_pick/default_candidate_source.rb`
  and `Issues::EnqueueEligible` at
  `app/services/issues/enqueue_eligible.rb`, the existing eligibility/queue
  boundaries RDR-066 designates as hold-enforcement points.

None of the above required new code for this closeout; they are cited because
RDR-066's implementation plan explicitly builds on them. No code specific to
RDR-066 itself (the Feature Intent record, its lifecycle, Inbox approval
actions, hold enforcement, or the named mode) was found anywhere in the
working tree.

## Gaps

### Feature Intent record and lifecycle (Implementation Plan step 1)

- Gap: no `FeatureIntent` model, migration, or approval-revision record
  exists. Evidence: `grep -rli "feature_intent\|FeatureIntent" app spec db`
  returns nothing; `db/schema.rb` has no `feature_intents` (or similarly
  named) table.
- Gap: none of the named lifecycle states (`discovering`, `design_open`,
  `needs_decision`, `ready_for_approval`, `approved_waiting_for_merge`,
  `released`, `revising`, `cancelled`) appear anywhere in `app/` or `spec/`.
- Existing tracking: no separate `docs/intent/` segment for feature
  intent/approval exists yet (`ls docs/intent/` has no `feature-intent` or
  `feature-approval` directory), and `docs/arrows/index.yaml` has no RDR-066
  entry — the LID arrow (HLD → LLD → EARS → tests → code) required by
  Implementation Plan step 1 has not been walked for this RDR.
- Existing tracking issue: #3862 (per RDR-066 Related Issues: "approval and
  release").

### `create_feature`/`lid_planning` attachment (Implementation Plan step 2)

- Gap: no code attaches design PRs or a proposed issue tree to a Feature
  Intent record, and no evidence-generation or unresolved-decision recording
  beyond what RDR-053 already ships was found.
- Existing tracking issue: #3863 (per RDR-066 Related Issues grouping).

### Inbox entries and Mark approved action (Implementation Plan step 3)

- Gap: `app/services/inbox/queue.rb` has no feature-question, design-review,
  or "Mark approved" entry type. No controller/action implements recording an
  approval actor, timestamp, feature revision, or accepted design-PR heads.
- Existing tracking issue: #3864 (per RDR-066 Related Issues grouping).

### Hold enforcement at every run entry point (Implementation Plan step 4; acceptance criteria 1–2)

- Gap: `Automation::Strategies::AutoPick::DefaultCandidateSource` eligibility
  rules (`app/services/automation/strategies/auto_pick/default_candidate_source.rb:16-30`)
  cover dependencies, in-flight runs, linked PRs, skip labels, tracker
  detection, and the trusted-creator allowlist — there is no release-hold
  check tied to a Feature Intent's approval/merge state.
- Gap: `Issues::EnqueueEligible` (`app/services/issues/enqueue_eligible.rb`)
  has no equivalent check, so eager queue seeding and dequeue are not gated
  either.
- Gap: none of the six required cases (direct human merge, Inbox approval,
  stale head after a new commit, incomplete design, bot merge without prior
  approval, abandoned/closed-unmerged design PR) has any corresponding
  reconciliation code or spec.
- Existing tracking issue: #3865 (per RDR-066 Related Issues grouping).

### Named operating mode (Implementation Plan step 5; acceptance criterion 3)

- Gap: no `human_led_feature_factory` (or equivalently named) profile exists
  in `app/services/configuration/profiles/`. The profile directory contains
  only `cost_capped_automated`, `manual_on_label`, `observe_only`,
  `quality_strict`, `solo_automated`, and `team_reviewed`.
- Gap: no onboarding default wiring proposes this mode for new
  accounts/projects.
- Existing tracking issue: #3872 (per RDR-066 Related Issues: "mode and
  onboarding").

### Rollout guard

- Gap: the Rollout Guard's named config gate ("a named project operating-mode
  setting, default off for existing projects") is not defined anywhere —
  there is no setting to gate on because the mode itself does not exist yet.
- Gap: RDR-066's own text states implementation issues are "held by the
  `planning` label until the finalized decisions are on the default branch."
  Finalization PR #3874 has now merged to `main`, so that hold should be
  lifted from #3862–#3865 and #3872, but lifting a GitHub label is a
  dependency-issue action, not a closeout-audit action, and is out of scope
  for this report.

## Acceptance criteria audit (issue #3873)

- "All auto/manual run entry points enforce the release hold." — **Not met.**
  No release-hold concept exists in any entry point (auto-pick, eager queue
  seeding, dequeue, manual `create_pr`, API, chat, UI).
- "Direct human merge, Inbox approval, stale head, incomplete design, bot
  merge, and abandoned PR cases are covered." — **Not met.** None of the six
  cases has shipped code or tests.
- "The named mode is available with independent merge and TDD controls." —
  **Not met.** The `human_led_feature_factory` mode does not exist.
- "The closeout PR visibly closes epic #3860 only if fully implemented." —
  **Satisfied by this audit's conclusion.** Because the criteria above are
  unmet, this closeout does not close #3860; see Conclusion.

## Issue and label hygiene

- No new gap issues were filed. Every gap identified above is already
  tracked by the open dependency issues #3862, #3863, #3864, #3865, and #3872
  that this closeout issue (#3873) itself depends on, consistent with the
  checklist's instruction to avoid catch-all or duplicate gap issues.
- This audit cannot verify current GitHub label state (no network/API access
  from this environment). Whoever applies this closeout should confirm
  #3862–#3865 and #3872 no longer carry the `planning` skip label now that
  finalization PR #3874 is on `main`, per RDR-066's own Related Issues note.

## Conclusion

RDR-066 should be marked **Partially Implemented**, not `Implemented`. The
design is Final and merged, and the RDRs it depends on (RDR-044, RDR-051,
RDR-053, RDR-056) have already shipped, but none of RDR-066's own scope — the
Feature Intent record, its lifecycle, Inbox approval actions, hold
enforcement at any run entry point, or the named `human_led_feature_factory`
mode — has shipped code or test evidence. All identified gaps are already
tracked by existing, still-open child issues (#3862–#3865, #3872). Per
acceptance criterion 4, this closeout does not close epic #3860; the closeout
PR uses `Tracks #3860` rather than `Closes #3860`.
