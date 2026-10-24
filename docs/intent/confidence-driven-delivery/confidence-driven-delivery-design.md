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

P01 implements this boundary with `projects.new_feature_delivery_policy`,
`projects.confidence_delivery_enrollment_enabled`, and immutable
`feature_intents.delivery_policy`. Both project fields default to the existing
approval-gated posture, and `FeatureIntents::AttachFromAgentRun` snapshots
`approval_gated` whenever enrollment is disabled. Project settings updates are
authorized by `ProjectPolicy#update?` and recorded as account activity.
P10 replaces the admission denial with `FeatureIntents::ReleaseIssue` and
`FeatureIntents::RunAdmission`: a passing scoped-readiness result records an
immutable release snapshot, reconciles only Paid's planning hold, and is
rechecked at queue and run admission. P10 also adds
`FeatureIntents::PublishHeldIssue`: a coherent-but-not-ready task is published
as a GitHub issue carrying the workflow-owned `planning` label, explicit
`Sub-issue of #N` parent text and `Depends on #N` prerequisite lines (the
project's dependency conventions), and a `FeatureIntentIssue` link that enters
the tree at `release_state: "held"`. Publication is idempotent per feature and
task identity: a durable create receipt is committed before GitHub is called,
then stores GitHub's returned issue identity before local synchronization; a
retry reconciles that number rather than relying on eventually-consistent body
search. Local reuse and remote-body recovery cover records lost after a
completed synchronization. Publication is serialized on a session advisory
lock without holding row locks across GitHub calls, and reads back the created
issue — marker, planning label, and dependency lines — before any local link
is committed. Speculative
alternatives are recorded deduplicated on the feature
(`feature_intents.speculative_alternatives`) and never filed as GitHub issues;
the authorized chat surface is the `publish_held_issue` tool, which reuses
`FeatureIntentPolicy#approve?` (project issue management). P11/P12 still own
policy-specific review and completion enforcement; selection or enrollment
alone never releases work.

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

`FeatureIntents::PublishHeldIssue` owns the speculative → planning-held
transition for confidence-driven features: coherent work is filed with the
planning hold and prerequisite links, while speculative alternatives stay in
Paid on the feature record. Coverage of the facet prerequisite mapping is
recorded as "unknown" at publication — confirming material coverage is the
assessor's judgment, so a freshly published issue can never pass readiness by
absence of evidence.

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
record is required. An issue may serve several designs; its planning hold
reconciles and its admission passes only when every linked confidence
design's scoped readiness passes — never an arbitrary single link, and
already-released snapshots stay immutable while later links reconcile.
Queue admission consumes the same result at auto-pick,
eager enqueue, dequeue, API/chat/manual starts and actual run creation. When a
direct admission encounters an unreleased confidence link, it invokes the same
release reconciliation before denying the run; already-released links read only
their local release evidence. The admitted snapshot is copied onto the created
run so later scope changes cannot silently alter active work.

Serialize the transition between an unstarted scope edit and run admission.
Admission either receives the revised ready scope or the already-started run
retains its original snapshot and the change becomes follow-up work. Do not
hold a database lock across GitHub network calls: use an idempotent pending
operation and verify its target revision before committing readiness.

External label edits request reconciliation: a removed hold re-checks
readiness, and an externally re-added planning hold on already-released work
is swept off by the periodic eager-queue pass rather than silently skipping
auto-pick (the label is itself a default skip label). Missing assessment
cannot be interpreted as a passing result, and projection failures must be
visible in Inbox/GitHub context. Do not let a ready-looking issue remain
silently blocked by a second, unexplained feature gate.

## Baseline and review dispatch

Confidence-driven runs and PRs use their admitted scope/design baseline.
Adapt conformance services to select the feature's policy explicitly. Under
this policy, later intent changes produce follow-ups, not feature-wide
amendment pauses or merge refusal solely because the feature revision changed.
Ordinary current-head review, CI, security, quality and merge policy continue.
Approval-gated features retain their exact-head/latest-approved-design guards.
This dispatch must also govern Inbox reasons so it cannot request an approval
that the active policy does not require.

## Inbox action projection

The shared `feature_decision` lane dispatches by the immutable feature policy.
Approval-gated records retain `ApprovalReadiness`, revision-bound Mark approved,
and stale-design handling. Confidence-driven records evaluate linked issue
mappings through `ScopedReadiness`. They enter the action Inbox only for an
open recorded human question or direction decision; assessment, investigation,
dependency waits, and ready scopes remain progress or history. The web and API
name the policy, scoped blockers, and concrete recovery action. They never turn
an answer or evidence correction into approval, release, admission, or a
completion claim.

## Follow-up and completion protocol

Classify a new finding against affected scope with agent judgment. Prefer
editing an unstarted issue when appropriate; otherwise create a deduplicated
follow-up issue. Its purpose, finding evidence, dependencies and feature link
must be explicit. Add `Depends on #<follow-up>` to the completion issue; the
follow-up must not depend on completion, which would make a cycle. Read back
the remote dependency. Failed writes retain a visible pending operation and
block a completion claim, not running implementation.

An unavailable or invalid impact assessment is not itself a finding. For a
confidence-driven feature, evaluation raises so the caller can retry before it
creates or edits any remote forward-work artifact. This avoids turning a
transient reviewer outage into speculative public issues while preserving the
already admitted baseline.

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

Test policy snapshots, disabling enrollment with active/held work, and mixed
approval-gated/confidence-driven features before testing 79/80 and unknown
results, design merge relevance, external label edits,
independent holds, GitHub failure/retry, scope-edit/admission races, mixed
policies and loss of access. Exercise findings before start, during a run and
after completion; ensure in-flight work is not paused with or without flags.
Verify dependency direction and no completion claim before readback. Scope
existing approval-gated tests explicitly when adding policy dispatch tests.
