# RDR-071: Confidence-Driven Issue Delivery and Feature Completion

## Metadata

- **Date**: 2026-09-22
- **Status**: Partially Implemented (see [2026-10-22 Final Acceptance Audit](#2026-10-22-final-acceptance-audit))
- **Type**: Product workflow and orchestration
- **Priority**: P1
- **Related RDRs**: [RDR-053](RDR-053-new-feature-creation.md), [RDR-066](RDR-066-feature-intent-approval-lifecycle.md), [RDR-067](RDR-067-approved-intent-conformance.md), [RDR-069](RDR-069-question-centered-chat-exploration.md), [RDR-070](RDR-070-facet-confidence-and-clarification.md)
- **Related Issues**: [#4309](https://github.com/viamin/paid/issues/4309) (epic — open; blocked on `CONFIDENCE-DELIVERY-002` and `013`, see [2026-10-22 Final Acceptance Audit](#2026-10-22-final-acceptance-audit))
- **Intent**: [Confidence-driven delivery](../intent/confidence-driven-delivery/confidence-driven-delivery-design.md)
- **Related Issues**: [#4309](https://github.com/viamin/paid/issues/4309) (shared umbrella), [#4324](https://github.com/viamin/paid/issues/4324) (RDR-071 closeout); implementation tasks are linked in the shared tree
- **Implementation tree**: [Human-centered Inbox delivery plan](human-centered-inbox-implementation.md)
- **Related Issues**: Epic [#4309](https://github.com/viamin/paid/issues/4309); closeout [#4324](https://github.com/viamin/paid/issues/4324); gaps [#4310](https://github.com/viamin/paid/issues/4310), [#4314](https://github.com/viamin/paid/issues/4314), [#4315](https://github.com/viamin/paid/issues/4315), [#4318](https://github.com/viamin/paid/issues/4318), [#4319](https://github.com/viamin/paid/issues/4319), [#4320](https://github.com/viamin/paid/issues/4320), [#4321](https://github.com/viamin/paid/issues/4321), [#4323](https://github.com/viamin/paid/issues/4323)

## Implementation Status

Partially Implemented as of 2026-10-12 (see
[2026-10-12 Closeout](#2026-10-12-closeout)). The approval-gated
feature lifecycle, admission recheck, and amendment/conformance guards
that this RDR deliberately reuses are shipped with passing tests; the
new confidence-driven policy is only partially implemented:
`CONFIDENCE-DELIVERY-001`, `014`, and `015` now have the P01 policy and
enrollment foundation. `db/schema.rb` carries the project selection and
immutable feature-policy snapshot; `FeatureIntents::RunAdmission` fails
closed for that policy until the complete delivery path is installed.
Release-audit, completion, and follow-up records now implement the
completion-blocking forward-work protocol; held-issue publication and
activation/isolation reporting remain incomplete.
The existing approval-gated policy and its review guards
(`IntentConformance::VerifyAtMerge`, `DesignAmendments::EvaluateImpact`,
`FeatureIntents::Release`, `FeatureIntents::RunAdmission`) remain the
authority for approval-gated features. The rollout guard has narrowed since
this audit: P09 (scoped readiness with 80/80 thresholds), P10 (publish held
issues and one automatic release contract), P11 (carry admitted intent to
builders and dispatch conformance by policy), and P12 (forward-work
follow-ups and completion) have since shipped, so `RunAdmission` no longer
denies confidence-driven admission outright. `RunAdmission#confidence_admission`
now reconciles an unreleased confidence-driven link through `ReleaseIssue`
and permits the run once a passing, scoped snapshot is released
(`app/services/feature_intents/run_admission.rb`). See the
[2026-10-22 Final Acceptance Audit](#2026-10-22-final-acceptance-audit) for
the current evidence and remaining gaps. See
[`audit-report-2026-10-12-rdr-071.md`](audit-report-2026-10-12-rdr-071.md)
for the criterion-by-criterion evidence as of that earlier date.

## Problem Statement

Whole-feature approval treats a feature as uniformly decided and holds its
entire issue tree. In practice, some issues become sufficiently understood
before others. Later findings should normally produce forward work, not
interrupt builders that are already executing a useful scope.

GitHub issues and dependency edges are Paid's operational unit. An actionable
issue should mean that its scope has enough certainty to work on. Readiness
must have the same meaning in Inbox, GitHub, auto-pick, and manual starts.

## Context and Policy Boundary

RDR-066 defines human approval of the whole feature and release after design
merge. RDR-067 includes impact pauses and merge checks against the feature's
latest approved revision. Existing services include `FeatureIntent`,
`FeatureIntents::ApprovalReadiness`, `DesignAmendments::EvaluateImpact`, and
`IntentConformance::VerifyAtMerge`. Parts are shipped; foundational work remains
tracked by #3862, #3863 and #3865. Reuse delivered primitives and revise
overlapping work rather than duplicate these systems.

Introduce an explicit **confidence-driven decision policy** for newly enrolled
features. The policy is snapshotted on the feature. Approval-gated features
retain the RDR-066/067 contract until deliberately migrated. This is a real
authorization-policy choice, not a fallback to whichever gate happens to pass.
Repository HLD/LLD/EARS remain the canonical design content.

## Decision

### Publish useful work, keep speculation visible

Keep speculative alternatives in the feature conversation. When an agent can
describe coherent purpose and scope, create a GitHub issue with the project's
effective planning hold and explicit dependencies. Link it to the feature and
its prerequisite facets. Show both speculative and filed work in Paid.

The issue tree includes a completion issue. Implementation and later follow-up
issues block that completion issue using explicit `Depends on #N` references.
Epics are coordination records, not runnable completion tasks. Keep completion
issues runnable once their real dependencies are satisfied.

### Release individual issues

For a confidence-driven issue, assess every material prerequisite facet using
RDR-070. Both scores must meet the project's configured thresholds (80/80 by
default), dependencies must permit the work, and the relevant design documents
must be merged. A human does not need to perform an additional whole-feature
approval click. Design PR merging still follows project review/merge policy.

Use relevant design scope, not every unresolved question or design PR anywhere
in the feature. The agent proposes and explains the facet/document mapping;
code checks identities, revisions and prerequisite state. If relevant design
scope cannot be established, keep the issue held and explain what is missing.
The merged design must express the scoped intent being released; newer chat
answers that change that scope require corresponding merged design updates.
A high score against new evidence does not make an older contradictory design
revision an adequate baseline.

Remove only the planning hold owned by this workflow. Preserve independent
human holds, unrelated labels, dependency edges, and execution policies. An
issue without blocking labels/dependencies is the external evidence that it
is ready. Reconcile that projection with an auditable release record carrying
scope revision, facet assessment revisions, threshold snapshot and merged
design baseline; this record implements the same contract, not another
mandatory approval gate. It also prevents a stale sync from starting work
before the visible transition completes.

Use one eligibility contract at auto-pick, eager enqueue, dequeue, API/chat,
manual and actual run admission. Editing/removing a label outside Paid asks
for reconciliation; it does not manufacture a missing assessment. Explain and
repair disagreement instead of leaving an apparently ready issue silently
blocked. GitHub failures leave the release pending and retry idempotently.

### Continue execution and fix forward

Once work has started, a changed answer, lower score, new finding, or amended
design does not pause or cancel it. Record the finding and create a follow-up
issue blocking the feature's completion issue. If the affected issue has not
started, updating its scope and prerequisites is also valid; revised unstarted
scope goes through the normal readiness check. No automatic transitive pause
set is introduced by this policy.

The builder uses its admitted scope and design baseline. New findings are
made available with clear distinction between its baseline and subsequent
intent. Review implementation against that admitted scope; a later feature
revision alone is not a reason to stop the run or block its PR. Existing CI,
security, code-quality, head-freshness and merge controls remain in force.
An actual failure of those independent controls is not converted into a
confidence exception.

Product intent changes still flow into repository design documents. Later
follow-up work receives the revised, merged scope through normal admission.
Do not require the active builder to retroactively implement the follow-up
scope or regenerate its whole plan.

### Completion and activation

Use feature flags to keep incomplete behavior from users where possible.
Confidence thresholds authorize scoped implementation, not feature exposure.
The completion issue verifies acceptance criteria and all follow-up
dependencies before reporting completion or readiness for flag activation.
Activation follows the project's release policy; completion is not itself
permission to change production settings.

When flag isolation is impossible, retain the same forward-work default:
file follow-ups or edit unstarted issues, without pausing in-flight work.
Explain exposure in the completion context. Isolation is not a new universal
admission prerequisite. Ordinary operational incident controls still exist.

Create follow-ups idempotently, with the finding, affected scope, evidence and
completion dependency. A finding discovered after completion reopens the
completion record or creates a linked new completion cycle; do not leave a
known gap represented as completed. Missing completion linkage or failed
GitHub writes remain visible pending work and prevent claiming completion,
without cancelling unrelated active runs. Recheck dependencies at closeout
to catch findings arriving concurrently with completion.

## Alternatives Considered

| Alternative | Decision and rationale |
|---|---|
| Retain mandatory whole-feature approval | Does not permit sufficiently understood issues to proceed independently. |
| File only ready issues | Hides useful decomposition; file coherent blocked issues and retain speculative work in Paid. |
| Use labels as an unaudited sole authority | GitHub is the visible contract, but admission must withstand sync and queue races. |
| Rehold all affected branches after new evidence | Interrupts normal execution; create completion-blocking follow-ups instead. |
| Require flag isolation for every change | Some changes cannot be isolated; findings still use forward work. |

## Rollout Guard

Add an explicit project policy selection; snapshot it only on newly enrolled
features. Default existing features to their established approval-gated policy.
The wiring issue must integrate all run admission paths and completion handling
before enabling automatic confidence-driven release. Do not rely on a UI-only
toggle. Trial assessments can run in shadow mode under RDR-070.

Disabling enrollment stops new confidence-driven features, preserves existing
policy snapshots and audit history, and does not pause active work or release
held issues. Any migration of an existing feature is explicit and reviewable.

## Implementation and Validation

Build the readiness contract, GitHub planning projection, unified admission,
builder context and policy-specific conformance, then follow-up/completion
handling. The implementation tree includes an explicit reconciliation task for
existing RDR-066/067 issues and shipped contracts.

Test unknown facets, 79/80 boundaries, unrelated uncertainty, relevant unmerged
designs, external label edits, failed sync, queued-run races and independent
human holds. Exercise a running issue receiving contradictory evidence with
and without a feature flag: it continues, the follow-up blocks completion, and
the admitted baseline remains stable. Test completion/finding concurrency and
mixed-policy projects. Audit actual code/tests before marking any RDR shipped.

## Trade-offs

Earlier issue execution accepts more follow-up work and requires honest
completion accounting. Flags reduce exposure but are not universally available.
Policy snapshots add an explicit boundary while approval-gated features exist;
they prevent accidental release or pausing caused by mixing incompatible rules.

## 2026-10-12 Closeout

Closeout issue [#4324](https://github.com/viamin/paid/issues/4324) compared
every `CONFIDENCE-DELIVERY-*` EARS claim and the RDR validation scenarios with
the application and its tests. Result: **Partially Implemented**. The reused
approval-gated foundations are verified and retained; the new confidence-driven
policy has no shipped EARS claim and remains blocked on the focused
policy/enrollment foundation [#4310](https://github.com/viamin/paid/issues/4310) (P01);
facets and prerequisite mapping [#4314](https://github.com/viamin/paid/issues/4314) (P05);
assessments and explanations [#4315](https://github.com/viamin/paid/issues/4315) (P06);
scoped readiness and 80/80 thresholds [#4318](https://github.com/viamin/paid/issues/4318) (P09);
held-issue publication and the unified release contract [#4319](https://github.com/viamin/paid/issues/4319) (P10);
immutable builder context and policy-specific review [#4320](https://github.com/viamin/paid/issues/4320) (P11);
completion-blocking follow-ups [#4321](https://github.com/viamin/paid/issues/4321) (P12);
and the independent facet-confidence closeout [#4323](https://github.com/viamin/paid/issues/4323) (C70)
work.

The rollout guard remains in force: automatic confidence-driven release is not
enabled, and no settings-only enrollment surface exists. This closeout tracks
[#4309](https://github.com/viamin/paid/issues/4309) and does not close it; E01's
own final acceptance audit decides closure from shipped evidence.

## 2026-10-22 Final Acceptance Audit

The umbrella audit verified the current delivery implementation rather than
the child issue states. `FeatureIntents::ReleaseIssue` and `RunAdmission`
release only Paid's planning hold from a passing, scoped snapshot and apply
the same contract at admission. `CompleteForwardWork` records forward work,
reads back completion dependencies, blocks completion for pending writes or
open work, and reopens a completed cycle for a later finding. Accordingly,
`CONFIDENCE-DELIVERY-011` and `012` are now marked implemented alongside the
previously shipped release, admission, baseline, and forward-work claims.

This RDR remains **Partially Implemented**. Coherent-but-not-ready issue
publication (`CONFIDENCE-DELIVERY-002`) and activation/isolation reporting
(`CONFIDENCE-DELIVERY-013`) still lack shipped evidence. Those gaps prevent
the RDR-070 shadow-mode guard from being treated as fully satisfied and prevent
closing #4309. The audit preserves the existing policy snapshots and active
runs and records the exact evidence in
[`audit-report-2026-10-22-human-centered-inbox-epic.md`](audit-report-2026-10-22-human-centered-inbox-epic.md).

## 2026-10-22 C71 Closeout

This audit **Tracks #4324** (C71) and ran its own RDR-071-scoped audit,
re-executing the focused suite directly in this session against a reachable
database (292 examples, 0 failures). Every
`CONFIDENCE-DELIVERY-*` claim except `002` and `013` has concrete code/spec
evidence; the reused RDR-066/067 approval-gated suite (`release_spec.rb`,
`mark_approved_spec.rb`, `approval_readiness_spec.rb`) passes unchanged and is
not claimed as RDR-071 evidence. See
[`audit-report-2026-10-22-rdr-071.md`](audit-report-2026-10-22-rdr-071.md) for
the criterion-by-criterion table, the behavioral-checklist results, and the
remaining-gap ownership ([#4319](https://github.com/viamin/paid/issues/4319)
P10, [#4321](https://github.com/viamin/paid/issues/4321) P12,
[#4323](https://github.com/viamin/paid/issues/4323) C70).

This closeout does not close #4324: C71 depends on P12, C69, and C70, and all
three remain open with owned gaps. It also does not close #4309 — it tracks
the epic and documents that #4309 was closed in error by
[PR #4567](https://github.com/viamin/paid/pull/4567) on 2026-10-22, contrary
to that PR's own bundled audit conclusion and the unresolved gaps above.
