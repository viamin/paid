# RDR-066 Umbrella Audit — 2026-10-01

- **RDR**: [RDR-066: Feature Intent and Approval Lifecycle](RDR-066-feature-intent-approval-lifecycle.md)
- **Audit date**: 2026-10-01
- **Umbrella issue**: [#3860](https://github.com/viamin/paid/issues/3860) (open — held by #3863 and #3865)
- **Closeout issue**: [#3873](https://github.com/viamin/paid/issues/3873) (the original 2026-09-17 closeout, retained as the umbrella audit surface)
- **Conclusion**: **Partially Implemented.** Three of the six
  implementation-plan steps have shipped with passing tests; steps 2, 4, and
  6 remain open and tracked by existing open issues #3863 and #3865.

This audit follows the [RDR Closeout Checklist](closeout-checklist.md). It
extends the 2026-09-17 closeout
([`audit-report-2026-09-17-rdr-066.md`](audit-report-2026-09-17-rdr-066.md))
with the evidence collected on 2026-10-01. The audit verifies shipped
behavior, tests, and documentation against RDR-066's approved design
(PR 3859) and finalization (PR 3874), the
[`docs/intent/feature-approval/`](../../intent/feature-approval/) LLD/EARS,
and the umbrella's six acceptance criteria in the
`## Implementation Status` table. Closed child issues are not treated as
sufficient evidence — only merged code and passing tests count.

## Method

Compared the working tree (RDR, LLD/EARS, `app/`, `db/`, `spec/`,
`docs/intent/`) against:

- RDR-066's `## Problem Statement`, `## Goals`, `## Decision`, and
  `## Validation` sections.
- `docs/intent/feature-approval/feature-approval-design.md` "Out of scope"
  boundary (which explicitly defers #3863 and #3865 to sibling issues under
  #3860).
- The six-row Implementation Status table on the RDR.
- The umbrella issue's child issues #3862–#3865, #3872, #3873.

Ran the focused RDR-066 test surface to confirm shipped behavior still passes
after the audit updates (206 examples, 0 failures — see Test Evidence).

## Acceptance criteria audit (umbrella #3860)

| RDR-066 criterion | Status | Evidence |
|---|---|---|
| Feature Intent record, lifecycle, and approval-revision binding | Shipped | `app/models/feature_intent.rb` (`STATUSES`, `APPROVABLE_STATUSES`, `record_approval!`, `record_criteria_clarity!`, `InvalidTransitionError`), `app/models/feature_intent_decision.rb`, `app/models/feature_intent_design_pr.rb`. Migrations `20260917025955_create_feature_intents_and_issue_links.rb`, `20260917072612_add_approval_fields_to_feature_intents.rb`, `20260917072615_create_feature_intent_decisions.rb`, `20260917072616_create_feature_intent_design_prs.rb`, `20260917072653_validate_feature_intents_approved_by_foreign_key.rb`, `20260917073211_add_criteria_clarity_to_feature_intents.rb`, `20260917093601_add_design_document_paths_to_feature_intents.rb`. Actor / time / approved-pr-heads jsonb snapshot / approved-design-revision all persisted. Tests: `spec/models/feature_intent_spec.rb` (`FEATURE-APPROVAL-009`/`010`), `spec/models/feature_intent_decision_spec.rb` (`006`/`007`), `spec/models/feature_intent_design_pr_spec.rb` (`008`). |
| `create_feature` / `lid_planning` attach design PRs and issue tree to a Feature Intent | **Gap** | `app/controllers/projects/agent_runs_controller.rb#create_feature_run_and_redirect` (`app/controllers/projects/agent_runs_controller.rb:1393-1442`) opens a GitHub issue and queues a `create_feature` agent run but never creates or links a `FeatureIntent` row; `lid_planning` paths in the same controller likewise do not attach output. Tracked by #3863. |
| Inbox feature-question, design-review, and "Mark approved" entries | Shipped | `app/services/inbox/queue.rb#feature_decision_entries` (`app/services/inbox/queue.rb:466-490`), `app/services/inbox/feature_decision_summary.rb`, `app/services/inbox/count.rb:49-51`, `app/services/feature_intents/approval_readiness.rb`, `app/services/feature_intents/criteria_clarity_review.rb`, `app/services/feature_intents/evaluate_criteria_clarity.rb`, `app/jobs/feature_intents/evaluate_criteria_clarity_job.rb`, `app/services/feature_intents/mark_approved.rb`, `app/policies/feature_intent_policy.rb`, `app/controllers/feature_intents_controller.rb`, `app/views/dashboard/_inbox_detail_feature_decision.html.erb`, `app/views/inbox/index.html.erb` nav filter chip "Feature Decision" (`FEATURE-APPROVAL-013`). Tests: `spec/services/inbox/queue_spec.rb:414,431,442,534` (`FEATURE-APPROVAL-013`), `spec/services/inbox/feature_decision_summary_spec.rb`, `spec/services/inbox/count_spec.rb:112` (`FEATURE-APPROVAL-013`), `spec/requests/inbox_spec.rb:692` (`FEATURE-APPROVAL-013`), `spec/services/feature_intents/approval_readiness_spec.rb`, `spec/services/feature_intents/criteria_clarity_review_spec.rb`, `spec/services/feature_intents/evaluate_criteria_clarity_spec.rb`, `spec/services/feature_intents/mark_approved_spec.rb`, `spec/policies/feature_intent_policy_spec.rb`, `spec/requests/feature_intents_spec.rb`. Dormant until #3863 wires `create_feature`/`lid_planning` output to a `FeatureIntent`. |
| Release hold enforced at every run entry point (auto-pick, eager queue, dequeue, manual `create_pr`) | **Gap** | `app/services/automation/strategies/auto_pick/default_candidate_source.rb` (`eligible_scope`, `eligible_for_dequeue?`) and `app/services/issues/enqueue_eligible.rb` (`eligible?` calling `DefaultCandidateSource.eligible_scope`) have no release-hold concept tied to `FeatureIntent#released?`. `app/temporal/activities/queue_agent_run_activity.rb` and `app/controllers/projects/agent_runs_controller.rb#create_run_and_redirect` / `create_feature_run_and_redirect` likewise bypass the gate. Tracked by #3865. |
| Direct human merge / Inbox approval / stale head / incomplete design / bot merge / abandoned PR reconciliation | **Gap** | No reconciliation service, controller, or spec matches the six cases. `FeatureIntents::MarkApproved` (`app/services/feature_intents/mark_approved.rb`) and `ApprovalReadiness` are the readiness+authorization choke points any future reconciliation path must call through. Tracked by #3865. |
| Named `human_led_feature_factory` operating mode with independent merge/TDD controls | Shipped | `Project::OPERATING_MODES` (`app/models/project.rb:51`), `app/services/configuration/profiles/human_led_feature_factory.rb` (profile targets with `operating_mode: "human_led_feature_factory"`, `tdd_mode: "non_strict"`, `auto_merge_mode: "off"` plus clarifying questions for `auto_merge_mode` and `tdd_mode` so the owner picks both independently), `app/services/onboarding/apply_default_posture.rb`, `app/services/onboarding/default_posture.rb`. Tests: `spec/services/configuration/profiles/human_led_feature_factory_spec.rb` (`FEATURE-APPROVAL-002`/`003`), `spec/services/onboarding/apply_default_posture_spec.rb` (`003`/`004`), `spec/system/onboarding_configure_defaults_form_spec.rb` (`003`/`004`), `spec/requests/onboarding_spec.rb` (`003`/`004`). |
| Rollout guard config gate | Shipped | `projects.operating_mode` column with `standard` default is the RDR's named config gate (`app/models/project.rb:51`, `validates :operating_mode` at `app/models/project.rb:361`, `human_led_feature_factory?` predicate at `app/models/project.rb:1161-1162`). Coverage: `spec/models/project_operating_mode_spec.rb` (`FEATURE-APPROVAL-001`, `005`). Disabling the mode is settings-only: `spec/models/project_operating_mode_spec.rb` lines 31-65 verify no run is enqueued or issue mutated when `operating_mode` changes — implementing the RDR's "Do not silently release held issues on mode disablement" rule. |

## Test Evidence

The following focused suite passed during this audit (206 examples, 0
failures):

```text
bundle exec rspec \
  spec/models/feature_intent_spec.rb \
  spec/models/feature_intent_decision_spec.rb \
  spec/models/feature_intent_design_pr_spec.rb \
  spec/models/project_operating_mode_spec.rb \
  spec/services/feature_intents/approval_readiness_spec.rb \
  spec/services/feature_intents/criteria_clarity_review_spec.rb \
  spec/services/feature_intents/evaluate_criteria_clarity_spec.rb \
  spec/services/feature_intents/mark_approved_spec.rb \
  spec/services/inbox/feature_decision_summary_spec.rb \
  spec/services/inbox/count_spec.rb \
  spec/services/inbox/queue_spec.rb \
  spec/services/configuration/profiles/human_led_feature_factory_spec.rb \
  spec/services/onboarding/ \
  spec/policies/feature_intent_policy_spec.rb \
  spec/requests/feature_intents_spec.rb \
  spec/requests/inbox_spec.rb \
  spec/requests/onboarding_spec.rb \
  spec/system/onboarding_configure_defaults_form_spec.rb
```

The `FEATURE-APPROVAL-013` Inbox nav-filter and queue tests
(`spec/requests/inbox_spec.rb:692`, `spec/services/inbox/queue_spec.rb:414/431/442/534`,
`spec/services/inbox/count_spec.rb:112`) all passed.

## Spec-coherence verification

`bin/coherence-check.mjs` ran cleanly for RDR-066's slice:

- `FEATURE-APPROVAL-001`–`013` spec IDs are defined in
  [`docs/intent/feature-approval/feature-approval-specs.md`](../../intent/feature-approval/feature-approval-specs.md)
  and marked `[x]` implemented.
- The matching `@spec FEATURE-APPROVAL-NNN` annotations appear in code and
  specs (`app/models/feature_intent.rb:3`,
  `app/models/feature_intent_decision.rb:8`,
  `app/models/feature_intent_design_pr.rb:8`,
  `app/models/project.rb:360`, `app/policies/feature_intent_policy.rb:4`,
  `app/services/feature_intents/*`, `app/services/inbox/queue.rb:465`,
  `app/services/inbox/count.rb:49`,
  `app/services/configuration/profiles/human_led_feature_factory.rb:16/22/49`,
  `app/services/onboarding/default_posture.rb:7`,
  `app/services/onboarding/apply_default_posture.rb:9`,
  `app/controllers/feature_intents_controller.rb:3`,
  `app/jobs/feature_intents/evaluate_criteria_clarity_job.rb:8`,
  `app/views/dashboard/_inbox_detail_feature_decision.html.erb:1`).
- No reverse-orphan or staleness findings touch this RDR; the reverse orphans
  reported by the coherence check (`CREATE-FEATURE-001`–`004`, `FEAT-NAME-001`)
  predate the feature-approval slice and belong to a separate
  create-feature intent segment, not RDR-066.

## Remaining Gaps

1. **`create_feature` / `lid_planning` attachment (#3863).** No code creates
   a `FeatureIntent` row outside tests. Until #3863 lands, the Inbox
   `feature_decision` entries and `Mark approved` action remain structurally
   inert for production projects — exactly as the LLD's "Out of scope"
   boundary states. Existing open issue #3863 owns this gap; no duplicate
   issue is needed.
2. **Run entry point hold enforcement and merge reconciliation (#3865).**
   `app/services/automation/strategies/auto_pick/default_candidate_source.rb`
   `eligible_scope` does not consult `FeatureIntent#released?` (or any other
   feature-intent state); `app/services/issues/enqueue_eligible.rb#eligible?`
   delegates to that scope. Manual `create_pr` paths in
   `app/controllers/projects/agent_runs_controller.rb` and the queue activity
   in `app/temporal/activities/queue_agent_run_activity.rb` likewise have no
   hold check. The direct human merge, Inbox approval, stale head, incomplete
   design, bot merge, and abandoned PR reconciliation cases have no
   corresponding service or spec. Existing open issue #3865 owns this gap;
   no duplicate issue is needed.

## Issue and label hygiene

- No new gap issues were filed. Every gap identified above is already tracked
  by the open dependency issues #3863 and #3865 that the umbrella's own
  child-issue list carries, consistent with the closeout checklist's
  instruction to avoid catch-all or duplicate gap issues.
- The original 2026-09-17 closeout issue #3873 has been retained as the
  umbrella audit surface; the 2026-10-01 PR uses `Closes #3873` for the
  partial-closeout audit and `Tracks #3860` to leave the umbrella visibly
  open, matching the closeout checklist's `Tracks` rule.

## Status Decision

**Partially Implemented** is the only supported closeout status. Steps 1, 3,
and 5 of the implementation plan shipped with executable test evidence; steps
2, 4, and 6 remain open and are already tracked by #3863 and #3865.
`Implemented`, `Superseded`, and `Abandoned` are unsupported by the current
code and documentation.

## Epic Closure

Do **not** close [#3860](https://github.com/viamin/paid/issues/3860). The PR
description must say `Tracks #3860` and `Closes #3873`, not `Closes` for the
umbrella. #3860 remains open until #3863 and #3865 land and a follow-up
audit re-verifies the acceptance criteria. The `epic` label is appropriate
(see `docs/rdrs/closeout-checklist.md` "Reconciling existing umbrellas"
section); it identifies the umbrella, which receives a final acceptance
audit once its children resolve, and does not silently exclude the issue
from auto-pick.
