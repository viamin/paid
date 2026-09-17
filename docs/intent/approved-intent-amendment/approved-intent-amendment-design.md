---
parent: PAID
prefix: INTENT-AMENDMENT
---

# Low-Level Design: Approved Intent Amendment

> Companion to the high-level design (`docs/high-level-design.md`). Implements
> the design-amendment and revision-impact slice of
> [RDR-067](../../rdrs/RDR-067-approved-intent-conformance.md) (#3869):
> routing product-level drift through amended RDR/LID PRs with human approval
> and merge, then rechecking open PRs and unstarted issues against the new
> baseline.

## Purpose

A conformance verdict of `material_drift` (or a human decision that the product
contract should change) must not be cleared by a one-PR exception. Product-level
changes route through an amended design that a human approves and merges before
affected work resumes. When the amended revision supersedes approval, Paid maps
the changed design claims onto the feature's branches, pauses the affected set
plus its dependency closure, holds uncertain branches for a human, and records
already-merged affected work as a follow-up decision instead of rolling it back.

## Scope

In scope (this segment):

- A minimal `FeatureIntent` record with its issue links and the
  `released` ⇄ `revising` transitions the amendment flow needs. The RDR-066
  Inbox decision flow and Mark approved action (#3864) extend this substrate
  with open decisions, linked design PRs, and the approval record — see
  `docs/intent/feature-approval/`.
- `IntentConformanceResolution` — the human decision record for a conformance
  verdict, with the structural bound that a one-PR implementation exception can
  never carry a product-contract change (behavior, constraints, scope,
  acceptance criteria).
- `DesignAmendment` and its state machine (`open → approved → merged`, or
  `abandoned`), including approval/head binding and merged-revision recording.
- Revision impact evaluation: semantic mapping of changed design claims onto
  linked open PRs, unstarted issues, and merged PRs; bounded pause set with
  dependency closure; uncertain-impact holds with human notification; merged
  follow-up decisions.
- Hold enforcement at the issue-selection boundary (auto-pick, eager enqueue,
  dequeue recheck) via the shared `DefaultCandidateSource.eligible_scope`.

Out of scope (owned by sibling issues under #3861): the independent conformance
reviewer run and verdict persistence (#3866), PR-scanner blockers and Inbox
escalation of drift verdicts (#3867), the final merge-activity guard (#3868),
evaluation and rollout telemetry (#3870), and the remaining RDR-066
issue-tree hold machinery and operating mode (#3862, #3863, #3865, #3872) —
the Inbox approval UI itself shipped under #3864, see
`docs/intent/feature-approval/`.

## Design

### Human resolution and the exception bound

A human resolving an intent-conformance decision records
`require_within_scope`, `implementation_exception`, or `design_amendment`,
bound to an actor, the target PR, and an exact `pr_head_sha`. The resolution
carries four product-contract flags (`changes_behavior`,
`changes_constraints`, `changes_scope`, `changes_acceptance_criteria`).
Model-level validation enforces the RDR-067 boundary: **any** product-contract
flag set to true requires `resolution_type: design_amendment` and a linked
`DesignAmendment`. A one-PR exception therefore cannot authorize a change to
approved behavior, constraints, scope, or acceptance criteria — those changes
exist only as amendments, which require human approval and merge before
affected work resumes. The exception stays bound to the recorded PR head; a
new head must be reviewed again (consumed by #3866/#3868).

### Amendment lifecycle

`DesignAmendments::Open` creates the amendment from a drift decision or
directly, binding it to the feature intent and the `superseded_revision` (the
feature's current approved design revision), and moves the feature to
`revising`. `DesignAmendments::Approve` records the human approval of the
amended design PR head. `DesignAmendments::Complete` records the merged
repository revision, advances the feature's approved design revision, returns
the feature to `released`, and evaluates revision impact.
`DesignAmendments::Abandon` returns the feature to `released` under the prior
revision without impact evaluation.

### Revision impact evaluation (ZFC boundary)

`DesignAmendments::EvaluateImpact` gathers the feature's linked branches:

- open PRs (`is_pull_request`, `github_state: open`),
- unstarted issues (non-PR, open, `paid_state` in the auto-pick-eligible
  set), and
- merged PRs (`merged_phase?`).

`DesignAmendments::ImpactReview` asks the semantic reviewer (via
`AgentHarness`, text-only, no tools) to map each candidate branch to
`affected`, `unaffected`, or `uncertain`, citing design claims copied from the
amendment evidence. Rails performs only structural validation: known branch
ids, terminal outcome enum, cited claims drawn from the provided claim list,
and a minimum confidence. **Failure fails closed**: an unsuccessful,
unparseable, invalid, or low-confidence review marks *every* candidate
`uncertain`.

The application then applies the bounded pause set:

- `affected` branches receive a `design_amendment_pauses` hold
  (`reason_code: affected`);
- the dependency closure — every issue that transitively depends on a held
  issue (`IssueDependency` local adjacency) — receives a hold
  (`reason_code: dependent`);
- `uncertain` branches receive a hold (`reason_code: uncertain`) **and** a
  blocking Inbox notification explaining the uncertainty with the cited
  claims;
- independently mapped (`unaffected`) branches receive nothing and remain
  runnable;
- merged PRs mapped `affected` (or uncertain, when the review failed) receive
  a `design_amendment_follow_ups` record plus a blocking notification
  presenting a follow-up design decision. Nothing is reverted, closed, or
  rolled back automatically; a human records the decision on the follow-up.

`DesignAmendments::ReleaseHold` releases a hold (with actor and reason) once a
branch has been rechecked against the new baseline or a human clears it.

### Hold enforcement

While a hold is active, the held issue is excluded from
`Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope`,
which is the shared selection boundary for scheduled auto-pick, eager queue
seeding, dequeue recheck, and enqueue eligibility. Independent branches are
untouched. Manual run-start gating rides on the RDR-066 hold machinery
(#3863/#3865) and is not duplicated here.

### Rollout guard

Per RDR-067's rollout guard, amendment enforcement is off by default: the
`approved_intent_amendments` feature flag (`FeatureFlags::DEFINITIONS`,
per-tenant opt-in via `tenant_settings.features`) gates
`DesignAmendments::Open`, the single entry point of the flow. Holds and
follow-ups cannot exist unless an amendment was opened under the flag, so
existing projects are structurally unaffected. When the RDR-066 named
operating mode (#3862/#3872) lands, this flag folds into the mode's persisted
setting; the cleanup criterion is recorded on the flag definition.

## Persistence

- `feature_intents` — project-scoped feature record (minimal substrate).
- `feature_intent_issues` — issue-tree links (unique per issue).
- `design_amendments` — amendment state, superseded/approved/merged revisions,
  drift evidence, evaluated impact.
- `design_amendment_pauses` — per-branch holds with reason, evidence, release
  audit (unique per amendment + issue).
- `design_amendment_follow_ups` — merged-work follow-up decisions with actor
  and decision audit.
- `intent_conformance_resolutions` — human resolution records with the
  product-contract bound.

Actor and transition audit live on the records themselves (explicit
`*_by_id`/`*_at` columns); no logidze on these operational tables.
