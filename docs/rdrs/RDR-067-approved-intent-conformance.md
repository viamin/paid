# RDR-067: Approved Intent Conformance for Feature PRs

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-09-16
- **Status**: Final
- **Type**: Review policy + orchestration safety
- **Priority**: P1
- **Related RDRs**: [RDR-022](RDR-022-auto-merge-pr-strategy.md) (Auto-Merge), [RDR-023](RDR-023-automation-modularization-architecture.md) (Automation Modularization), [RDR-051](RDR-051-lid-aware-agent-runs.md) (LID-Aware Agent Runs), [RDR-056](RDR-056-strict-test-driven-development-mode.md) (TDD Modes), [RDR-066](RDR-066-feature-intent-approval-lifecycle.md) (Feature Intent and Approval Lifecycle)
- **Related Intent**: `docs/high-level-design.md`, `docs/intent/auto-merge-strategy/`, `docs/intent/operator-inbox/`, and new feature-approval/conformance segments
- **Related Issues**: [#3861](https://github.com/viamin/paid/issues/3861) (epic), #3866–#3870 (review, enforcement, amendment, evaluation), #3871 (closeout). The design was approved and merged in [#3859](https://github.com/viamin/paid/pull/3859); implementation issues remain held by the `planning` label until the finalized decisions are on the default branch.
- **Related Tests**: TBD

## Problem Statement

The approved feature design should authorize implementation within its scope, not every implementation choice an agent might make. Paid's current PR review and auto-merge checks cover CI, review feedback, freshness, dependencies, and project policy; they do not compare a feature PR with the exact human-approved design revision. A clean PR can therefore change product behavior, constraints, or acceptance criteria and still be eligible for auto-merge. Conversely, requiring humans to review every PR would return the work to the right side of the process.

Paid needs an independent, auditable conformance verdict on each feature PR. Material drift and uncertainty must stop auto-merge and ask a human. In-scope implementation choices should proceed under the project's existing merge controls.

## Goals

1. Compare the current PR head against the approved design revision that authorized its feature tree.
2. Require a separate review verdict, not only the implementing agent's self-report.
3. Block auto-merge on material drift, uncertainty, missing evidence, or stale verdicts.
4. Route actionable human decisions through the Inbox, with the disputed claim and change visible.
5. Allow scoped execution to continue while a design amendment pauses affected issues and dependents.
6. Preserve current CI, security, quality, dependency, review, auto-merge, and optional human test-review policy.

## Non-Goals

- Prove semantic equivalence of arbitrary code and prose mechanically.
- Require exact adherence to an RDR's suggested implementation technique when approved behavior and constraints are satisfied.
- Let an LLM clear an auto-merge block by writing labels or comments outside the recorded verdict service.
- Make this conformance verdict a replacement for code review, tests, security review, or branch protection.
- Expand the mode to ordinary bugs and maintenance. A bug caused by a flawed design decision enters the design-amendment flow; an implementation defect stays in the ordinary bug workflow.

## Context and Research Findings

- `Automation::Strategies::AutoMerge` consumes a signal snapshot and checks project policy, owner approval, CI, mergeability, feedback, review freshness, and dependencies. It has no approved-intent signal.
- The PR scanner already persists blockers and exposes approval-only blockers through the Inbox. A distinct intent-conformance blocker can use the same visible scanning model, but it must not be mistaken for ordinary owner approval.
- `Lid::InjectIntoPrompt` and the LID Planning PR path give agents design context and report coherence. Prompt instructions and coherence checks do not enforce a PR-specific human-approval boundary.
- RDR-056 provides strict and non-strict test-review modes. A changed test plan that changes the approved product contract must return to design review; a project's strict human test gate remains valid.
- The approved design may span RDR and LID PRs. Conformance needs the merged repository revision, the current PR head, and the feature revision, not an unversioned search result or the latest text on an open branch.

## Decision

Introduce an **Intent Conformance Verdict** for every implementation PR in the named feature operating mode. The verdict is produced by a review run separate from the implementing run, using `agent_harness` and the same trusted-content rules as other agent prompts. It compares the PR diff and test/verification evidence with the feature's approved RDR and required LID artifacts at the approved merged revision.

The review returns a structured outcome:

| Outcome | Meaning | Automation action |
|---|---|---|
| `within_scope` | The PR preserves approved behavior, constraints, scope, and acceptance criteria. | Existing merge checks may proceed. |
| `material_drift` | The PR changes one of those commitments. | Block auto-merge and create a human decision. |
| `uncertain` | The review cannot reliably establish conformance. | Block auto-merge and create a human decision. |
| `not_evaluated` | Evidence or review failed, or no current verdict exists. | Block auto-merge and retry or surface the failure. |

Each verdict records PR head SHA, approved design revision, reviewer run and model, cited design claims, cited diff locations, reasoning summary, timestamp, and whether a human resolution superseded it. A changed PR head or changed approved design invalidates the verdict. An implementation agent may report suspected drift early, but that report cannot itself authorize merge.

### Materiality boundary

Material drift means changing approved behavior, constraints, in/out scope, or acceptance criteria. Code organization, libraries, decomposition, and internal implementation details remain agent choices unless the design explicitly made one a binding constraint. The reviewer must explain which approved claim is at issue and how the PR differs. A low-confidence or contradictory assessment is `uncertain`, not `within_scope`.

The LLM makes the semantic judgment. Rails enforces structural safety: whether the verdict belongs to the current PR head and design revision, whether it is a terminal allowed outcome, whether a human decision exists, and whether all merge blockers are clear. This follows Paid's Zero Framework Cognition rule without trusting prose or labels as authority.

### Merge enforcement and race safety

Add conformance to the PR scanner's blocker snapshot and to the final merge activity's precondition check. The final check must refresh or verify PR head, approved revision, and verdict identity immediately before requesting merge, so a push or design amendment between scan and merge cannot bypass the gate. No fallback interprets a missing verdict as approval. Existing branch protection and configured review/quality checks remain additive.

### Human decision and amendment

For `material_drift` or `uncertain`, the Inbox item shows the approved claim, proposed deviation, PR diff reference, reviewer evidence, and affected issue branch. The human may:

1. require the agent to bring the PR back within scope;
2. approve a bounded one-PR implementation exception that leaves the product contract intact; or
3. open a design amendment when product behavior, constraints, scope, or acceptance criteria should change.

A product-level amendment does not clear a PR by exception. It updates the repository design through the RDR/LID review path, obtains human approval, and merges before affected work resumes. The conformance verdict then runs against the new approved revision. Human resolution records actor, target PR head, scope, and reason; a new commit invalidates a one-PR exception unless the changed head is reviewed again.

### Revision impact

When a design revision supersedes approval, Paid identifies open PRs and unstarted issues linked to that feature. It asks the semantic reviewer to map changed design claims to affected branches; the application applies the resulting bounded pause set and dependency closure. Independent branches continue. If impact cannot be established confidently, hold the uncertain branch and surface it to a human. Already merged work is not rolled back automatically; the Inbox presents it as a follow-up design decision if the revision affects it.

## Alternatives Considered

1. **Trust the implementing agent's LID phase report.** Rejected because it is a self-report, may miss drift, and is not tied to the final PR head.
2. **Use keyword or path matching to detect drift.** Rejected because the question is semantic; such rules would confuse implementation freedom with contract changes and miss behavior changes in familiar files.
3. **Require human review on every feature PR.** Rejected because it spends human attention late even when the PR follows a settled design.
4. **Use a GitHub label as the sole conformance state.** Rejected because labels are editable and do not bind a verdict to a PR head and design revision.

## Trade-offs and Consequences

- A separate review adds cost and latency to each PR. It should reduce late human review and rework only if verdicts are accurate; measure both sides.
- Semantic review can raise false alarms or miss drift. Uncertainty fails closed, but a high false-alarm rate would defeat the operating mode. Evaluate it with representative accepted and intentionally drifted PRs before broad rollout.
- Design amendments may pause work already in progress. A dependency-scoped pause avoids stopping unrelated work but requires auditable impact mapping and a conservative fallback.
- Human one-PR exceptions add flexibility, yet their narrow scope and head binding are essential so they cannot quietly rewrite the product contract.

## Rollout Guard

- **Config gate**: conformance enforcement applies only to projects using the RDR-066 named feature operating mode and only to feature PRs bound to a released Feature Intent. Existing projects remain off by default.
- **Wiring issue**: the first conformance implementation issue adds the signal and final-merge guard together. Until both are active, the mode cannot release feature implementation issues; do not run in an unsafe partially enabled state.
- **Rollback**: stop releasing new features in the mode and hold its outstanding merge candidates until the guard is restored or a human explicitly migrates them to another policy. Do not interpret a disabled reviewer as a passing verdict.
- **Cleanup**: after closeout and measured rollout, remove temporary shadow-review paths; keep the versioned verdict and merge precondition.

## Implementation Plan

1. Add the verdict contract, persistence, trusted review prompt, and independent reviewer run. Write LID EARS claims and failing-first tests before code.
2. Integrate the current-head/current-design verdict into PR scanner blockers and Inbox escalation. Show the claim-to-diff explanation and human resolution actions.
3. Enforce the same version check in the final merge activity, including race tests for a new PR commit or design revision after scanning.
4. Implement design amendment and impact mapping across open PRs, unstarted issues, and dependency closure; reconcile already merged affected work through a follow-up decision.
5. Add representative offline evaluations and rollout telemetry for false alarms, missed drift, human-review load, and cost. Run the RDR closeout audit.

## Validation

- A PR with a current `within_scope` verdict may proceed only if all existing merge controls pass.
- A material behavior change, widened scope, changed acceptance criterion, uncertain verdict, missing verdict, or reviewer failure prevents auto-merge and creates a legible Inbox item.
- A new PR commit or design revision invalidates the old verdict and any one-PR exception. A concurrent update between scan and merge also prevents merge.
- A human-approved bounded implementation exception applies only to the named PR head; a product-contract change requires a merged, reapproved design amendment.
- A design revision pauses affected issues and dependents, leaves independent branches runnable, and identifies already merged affected work for a human decision.
- Human-gated TDD continues to work when configured; automated test review is available without a routine human pause.
- Rollout reports PR-to-merge conversion, human review time, false-alarm rate, escaped intent changes, rework, reviewer cost, and time to delivery.
