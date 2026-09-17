# RDR-066: Feature Intent and Approval Lifecycle

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-09-16
- **Status**: Partially Implemented
- **Type**: Product workflow + orchestration
- **Priority**: P1
- **Related RDRs**: [RDR-044](RDR-044-configuration-profiles-chat.md) (Configuration Profiles), [RDR-051](RDR-051-lid-aware-agent-runs.md) (LID-Aware Agent Runs), [RDR-053](RDR-053-new-feature-creation.md) (New Feature Creation), [RDR-056](RDR-056-strict-test-driven-development-mode.md) (TDD Modes), [RDR-067](RDR-067-approved-intent-conformance.md) (Approved Intent Conformance)
- **Related Intent**: `docs/high-level-design.md`, `docs/intent/operator-inbox/`, `docs/intent/inbox-foundation/`, `docs/intent/lid-aware-agent-runs/`, and a new feature-approval segment (not yet created — see Implementation Status)
- **Related Issues**: [#3860](https://github.com/viamin/paid/issues/3860) (epic), #3862–#3865 (approval and release), #3872 (mode and onboarding), #3873 (closeout). The design was approved and merged in [#3859](https://github.com/viamin/paid/pull/3859); implementation issues remain held by the `planning` label until the finalized decisions are on the default branch.
- **Related Tests**: TBD

## Implementation Status

RDR-066 is **Partially Implemented** as of 2026-09-17. The design is Final and
merged (design PR #3859, finalization PR #3874), and the prerequisite RDRs it
builds on (RDR-044 Configuration Profiles, RDR-051 LID-Aware Agent Runs,
RDR-053 New Feature Creation, RDR-056 TDD Modes) have already shipped. None of
RDR-066's own scope has shipped code or test evidence yet: no `FeatureIntent`
record, no lifecycle states, no Inbox approval action, no hold enforcement at
any run entry point, and no `human_led_feature_factory` operating mode. See
[`audit-report-2026-09-17-rdr-066.md`](audit-report-2026-09-17-rdr-066.md) for
the full evidence trail.

| Criterion | Status | Evidence |
|-----------|--------|----------|
| Feature Intent record, lifecycle, and approval-revision binding | Gap | No `FeatureIntent` model, migration, or lifecycle state exists anywhere in `app/`, `spec/`, or `db/schema.rb`; tracked by #3862 |
| `create_feature`/`lid_planning` attach design PRs and issue tree to a Feature Intent | Gap | No attachment code found; tracked by #3863 |
| Inbox feature-question, design-review, and "Mark approved" entries | Gap | `app/services/inbox/queue.rb` has no such entry types; tracked by #3864 |
| Release hold enforced at every run entry point (auto-pick, eager queue, dequeue, manual `create_pr`) | Gap | `app/services/automation/strategies/auto_pick/default_candidate_source.rb` and `app/services/issues/enqueue_eligible.rb` have no release-hold concept; tracked by #3865 |
| Direct human merge / Inbox approval / stale head / incomplete design / bot merge / abandoned PR reconciliation | Gap | No corresponding code or specs found; tracked by #3865 |
| Named `human_led_feature_factory` operating mode with independent merge/TDD controls | Gap | `app/services/configuration/profiles/` has no such profile; tracked by #3872 |
| Rollout guard config gate | Gap | No gate exists because the mode itself has not shipped |

### 2026-09-17 Closeout audit

This closeout ([#3873](https://github.com/viamin/paid/issues/3873)) found no
RDR-066-specific implementation in the working tree. All identified gaps are
already tracked by the still-open dependency issues #3862–#3865 and #3872, so
no new gap issues were filed. Per the closeout checklist, this PR does not
close umbrella issue #3860 — it uses `Tracks #3860` — because the acceptance
criteria are not yet met. See the audit report for full evidence.

## Problem Statement

Paid can turn a feature brief into an RDR PR and implementation issue tree, but it has no feature-level approval boundary between design and execution. RDR-053 deliberately files issues before the RDR PR merges so humans can review the decomposition. Existing auto-pick eligibility does not know whether the design was approved, and the existing Inbox does not carry the complete RDR/LID decision flow. A project can therefore spend agent time implementing a feature whose product decisions remain open.

The desired operating mode shifts human attention to discovery, design, and decisions. Once a human approves a complete design, Paid may execute the whole feature tree within that approved scope. Implementation begins only after the approved design is merged into the repository.

## Goals

1. Let Paid research a feature and ask humans only the product, scope, and design questions the repository cannot answer.
2. Give an Inbox user a single, reviewable feature decision flow covering evidence, alternatives, RDR, required LID artifacts, and the proposed issue tree.
3. Record a named human approval of an exact design revision. Any project member with Inbox access may approve.
4. Keep the issue tree visible during design review but ineligible for implementation until the full approved design is merged.
5. Make the workflow a named project operating mode: opt-in for existing projects and the default offered during new account/user onboarding.
6. Preserve independent project choices for auto-merge and human-gated tests.

## Non-Goals

- Rename the Inbox. The present name may deserve a separate product decision.
- Replace ordinary bug or maintenance workflows. A bug caused by a flawed approved design enters this feature design-amendment path; an implementation defect does not need a new feature approval.
- Require one fixed discovery checklist or a prototype for every feature.
- Change CI, security, quality, review, or merge policy as a side effect of choosing this mode.
- Treat a repository document's merge as sufficient proof of approval when the design is incomplete.

## Context and Research Findings

- RDR-053's `create_feature` path gathers a brief, opens a docs-only RDR PR, files an issue tree before merge, and may chain into `lid_planning`. Its output contract checks RDR structure, not whether all product questions have human answers.
- RDR-051's Planning PR and LID prompts provide a repository-native design surface. For a LID project, RDR and HLD/LLD/EARS changes together form the design to approve; implementation must not run while the conversion is still in flight.
- `Inbox::Queue` already composes typed clarifying-question, plan-review, merge-approval, action-required, escalated-PR, and manual-review entries. Its clarifying-question presentation supports PR-backed rows, while current question producers are issue-centric. Extend that surface instead of building a parallel approval UI.
- The Inbox currently scopes several entries to a project's effective owner and auto-pick status. Feature-design decisions must instead be visible and actionable to every project member who has Inbox access, including when auto-pick is off during planning.
- `Automation::Strategies::AutoPick::DefaultCandidateSource` and `Issues::EnqueueEligible` select runnable issues from local state. A label or text dependency alone is not an authorization record and cannot protect manual starts or already-queued runs.
- RDR-044 ships curated configuration profiles, but a profile cannot express a feature's approval actor, document revision, issue-tree hold, or release transition. The mode should use that profile surface only after the workflow exists.
- RDR-056's implemented strict and non-strict TDD modes already make test review configurable. This mode should prefer automated test review while remaining compatible with strict human review when selected.

## Decision

Introduce a **Feature Intent** record that links one feature brief, discovery evidence, design PRs, issue tree, human decisions, and approval revisions. Repository documents remain the source of design content; Paid persists the authorization and linkage needed to enforce the workflow. An approved revision identifies the exact design PR heads the human considered and the merged repository revision that becomes the execution baseline.

### Feature lifecycle

`discovering → design_open → needs_decision → ready_for_approval → approved_waiting_for_merge → released → revising → released | cancelled`

The implementation should model transitions explicitly and reject invalid transitions. A feature may have multiple design PRs, including an RDR PR and one or more LID Planning PRs. Their order and branch arrangement are implementation choices, but **all required design artifacts must be merged** before `released`. The feature record must identify which artifacts are required for the project's LID mode.

### Discovery and approval readiness

Paid researches the relevant code and documents, presents alternatives with evidence, and asks adaptive questions in the Inbox. It may attach user-flow sketches, previews, or prototypes where they help settle a decision. Each open decision must point to the design claim it affects. The approval action is unavailable while a material question remains unanswered, an `[inferred]` product decision lacks human confirmation, the scope is ambiguous, or acceptance criteria cannot distinguish an in-scope PR from drift. An AI readiness assessment can explain the gap; deterministic state checks enforce that the required decisions were resolved and the target PR heads are current. Do not equate a structurally complete RDR with a decision-ready RDR.

### Approval sources and revision binding

An Inbox **Mark approved** action records the human actor, time, feature revision, document PR heads, and accepted issue-tree revision. It may allow Paid to auto-merge the design PRs if the project's existing auto-merge policy permits it. A direct human merge on GitHub may serve as the approval event when the same readiness checks pass. A Paid/bot merge without a prior human approval does not create approval. Edits to a design PR after the Inbox approval invalidate that approval until the human reviews the new head.

GitHub merge identity must be verified from provider data rather than inferred from the presence of a merge commit or a label. A direct-merge approval must also satisfy the project's membership/Inbox access policy; GitHub merge permission alone must not silently widen who can approve a Paid feature. If Paid cannot establish an authorized human merger or a recorded human approval, the feature stays held and appears in the Inbox with a reason.

### Issue-tree hold and release

The proposed issue tree is created while the design is open, linked to the Feature Intent record and shown during approval. It is blocked at **every** implementation entry point, including eager queue seeding, scheduled auto-pick, dequeue, and manual `create_pr` starts. A held issue may still be edited or discussed. The hold is removed only when approval is current and all required design PRs have merged. The release transaction records the approved repository revision; every subsequent run carries that revision. An abandoned or closed-unmerged design PR cancels or returns the feature to design rather than releasing orphaned issues.

One approval authorizes the whole tree. Paid may split, reorder, or add implementation tasks within the approved scope without a new human approval. A task that adds behavior or expands scope requires design revision under RDR-067. The tree's parent/child and dependency text remains useful for scheduling, but is not the approval mechanism.

### Operating mode

Add a named project mode such as `human_led_feature_factory` through the existing configuration profile experience. It enables the feature approval workflow for new features and selects non-strict TDD as its suggested test-review posture. It does **not** silently change `auto_merge_mode`; the owner still chooses whether Paid may merge PRs. Existing projects opt in. New-account/user onboarding offers this as the default project posture. Features already underway keep their current workflow unless deliberately migrated.

## Alternatives Considered

1. **Configuration profile only.** Rejected because settings cannot represent per-feature approval, version binding, or a held issue tree.
2. **Treat RDR PR merge alone as approval.** Rejected because a human could merge an incomplete design, and Paid may auto-merge after explicit Inbox approval. Both paths need one readiness and provenance contract.
3. **Create issues only after design merge.** Rejected because reviewers need to inspect and change the decomposition before authorizing the tree.
4. **Use skip labels or dependency text as the sole hold.** Rejected because project labels are configurable and manual/queued starts need the same hard gate.

## Trade-offs and Consequences

- Human time moves earlier and the agent receives a clearer execution contract, but feature startup gains a design-review wait.
- A feature-level record and cross-PR state machine add persistence and reconciliation work. This is justified because the current issue, PR, and label records cannot safely encode the authorization relationship.
- Direct GitHub merges require attribution and sync reconciliation; when attribution is uncertain, Paid must fail closed and explain what human action clears the hold.
- Adaptive discovery can become lengthy. Measure total human time per accepted feature, not the fraction spent before coding alone.

## Rollout Guard

- **Config gate**: a named project operating-mode setting, default off for existing projects. New-account/user onboarding proposes the mode as the default for newly created projects; onboarding still displays the chosen settings before applying them.
- **Wiring issue**: the first implementation issue adds the setting and gates feature-specific issue release and run admission. No issue may depend only on UI visibility or a label to enforce the hold.
- **Rollback**: stop new feature enrollment and new releases into this mode; preserve approval history and held feature state for an explicit migration decision. Do not silently release held issues on mode disablement.
- **Cleanup**: after the RDR closeout and measured rollout, remove temporary rollout paths while retaining the named mode and per-feature approval records.

## Implementation Plan

1. Add the Feature Intent model, relationships, approval-revision record, transition services, authorization, and audit events. Update HLD/LLD/EARS before production code and write failing-first behavior tests.
2. Extend `create_feature` and `lid_planning` to attach design PRs and the proposed issue tree to a Feature Intent. Generate evidence and unresolved-decision records without fabricating human answers.
3. Add Inbox entries and actions for feature questions, design review, and Mark approved. Reuse PR-backed clarifying-question presentation where possible; make approval readiness and stale-head reasons visible.
4. Enforce the hold at every issue selection and run-start boundary. Reconcile direct GitHub human merges, bot merges after Inbox approval, PR updates, and abandoned PRs.
5. Add the named configuration profile and onboarding default, preserving existing auto-merge and strict-TDD settings as independent choices.
6. Run the RDR closeout audit, including status and intent-doc reconciliation.

## Validation

- A feature's issue tree is visible before approval but cannot start via auto-pick, eager queue, dequeue, API, chat, or manual UI.
- Inbox approval of a design PR's old head becomes stale after a new commit; Paid cannot merge or release it without a fresh decision.
- A complete direct human merge counts as approval; an incomplete human merge remains held with a clear Inbox explanation; an unapproved bot merge never counts.
- For a LID project, merging only the RDR PR does not release implementation; all required LID artifacts must merge.
- A user with Inbox access can approve and the actor/revision are auditable; a user without access cannot.
- A rejected design PR cannot leave runnable orphan issues.
- Existing feature work is unaffected until deliberately migrated; human-gated TDD and auto-merge settings remain independent.
- Rollout reports total human time, discovery/design time, late review time, delivery time, rework, accepted quality, and held-feature age against a comparable baseline.
