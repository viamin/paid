---
parent: PAID
prefix: CONFIDENCE-DELIVERY
---

# Confidence-Driven Delivery

## Scope and policy selection

[RDR-071](../../rdrs/RDR-071-confidence-driven-issue-delivery.md) owns this
planned issue-level delivery policy. A project selects policy for newly
enrolled features; each feature retains that policy snapshot. Existing
approval-gated features use RDR-066/067 and the feature-approval and
approved-intent segments. Policy selection is explicit, not inferred from
which score or approval happens to pass. Enrollment is disabled until the
admission, review and completion integrations are complete.

## State and transitions

| Work state | Meaning | Next step |
|---|---|---|
| Speculative | Purpose/scope still being explored in chat | Clarify or discard |
| Planning-held issue | Coherent GitHub issue, incomplete prerequisites | Assess facets and resolve dependencies/design work |
| Release pending | Prerequisites pass, GitHub projection not yet reconciled | Idempotently reconcile planning hold |
| Ready | Sufficient scoped confidence and no independent blockers | Normal Paid queue/admission |
| Started | Immutable admitted scope/evidence/design baseline | Execute; new findings become forward work |
| Completion pending | Implementation/follow-up dependencies or verification remain | Resolve dependencies and verify acceptance |
| Complete | Acceptance verified and no unresolved completion dependencies | Activation follows project release policy |

These are behavioral states, not a mandate to duplicate the existing issue and
run state machines with another status enum.

## Readiness and admission

Reuse `FeatureIntent`/issue links and existing dependency resolution. The
facet-confidence service supplies current assessments and material mapping.
Require relevant merged design artifacts, adequate coverage, and each score
at threshold. The applicable merged design must agree with the released scope
and evidence; an older contradictory revision is not sufficient merely because
it has merged. A research issue is scoped to its investigation; if it has
required design artifacts they still must merge, but unresolved implementation
documents outside its scope do not block the investigation.

Record an immutable release snapshot: issue scope revision, feature policy,
material facet/direction IDs, assessment/evidence revisions, thresholds and
merged design baseline. Reconcile the workflow-owned planning label and
dependencies without erasing unrelated human holds. No new human approval
record is required. Queue admission consumes the same result at auto-pick,
eager enqueue, dequeue, API/chat/manual starts and actual run creation.

Serialize the transition between an unstarted scope edit and run admission.
Admission either receives the revised ready scope or the already-started run
retains its original snapshot and the change becomes follow-up work. Do not
hold a database lock across GitHub network calls: use an idempotent pending
operation and verify its target revision before committing readiness.

External label removal requests reconciliation. Missing assessment cannot be
interpreted as a passing result, and projection failures must be visible in
Inbox/GitHub context. Do not let a ready-looking issue remain silently blocked
by a second, unexplained feature gate.

## Baseline and review dispatch

Confidence-driven runs and PRs use their admitted scope/design baseline.
Adapt conformance services to select the feature's policy explicitly. Under
this policy, later intent changes produce follow-ups, not feature-wide
amendment pauses or merge refusal solely because the feature revision changed.
Ordinary current-head review, CI, security, quality and merge policy continue.
Approval-gated features retain their exact-head/latest-approved-design guards.
This dispatch must also govern Inbox reasons so it cannot request an approval
that the active policy does not require.

## Follow-up and completion protocol

Classify a new finding against affected scope with agent judgment. Prefer
editing an unstarted issue when appropriate; otherwise create a deduplicated
follow-up issue. Its purpose, finding evidence, dependencies and feature link
must be explicit. Add `Depends on #<follow-up>` to the completion issue; the
follow-up must not depend on completion, which would make a cycle. Read back
the remote dependency. Failed writes retain a visible pending operation and
block a completion claim, not running implementation.

The completion issue depends on all implementation and follow-up work and
verifies feature acceptance. Recheck findings/dependencies against the version
being closed; a concurrent new finding keeps completion open. If already
closed, reopen or create a linked completion cycle. Never claim user exposure
was prevented solely because a flag exists: completion verifies the actual
isolation/activation arrangement. When isolation is impossible, report that
fact and continue forward work without pausing active runs.

## Decisions and alternatives

| Decision | Rationale | Alternative |
|---|---|---|
| Initial issue-level thresholds | Scope-specific certainty permits independent work | Whole-feature approval |
| Explicit feature policy snapshot | Avoids combining incompatible lifecycle rules | Infer policy from global flags |
| GitHub projection plus release audit | Readiness is visible and resists asynchronous races | Labels alone or invisible gate |
| Follow-ups block completion | Preserves useful execution as understanding changes | Pause affected running branches |

## Validation

Test 79/80 and unknown results, design merge relevance, external label edits,
independent holds, GitHub failure/retry, scope-edit/admission races, mixed
policies and loss of access. Exercise findings before start, during a run and
after completion; ensure in-flight work is not paused with or without flags.
Verify dependency direction and no completion claim before readback. Scope
existing approval-gated tests explicitly when adding policy dispatch tests.
