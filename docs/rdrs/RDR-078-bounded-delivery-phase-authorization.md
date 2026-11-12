# RDR-078: Bounded Delivery-Phase Authorization

## Metadata

- **Date**: 2026-10-24
- **Status**: Proposed
- **Acceptance**: Not accepted. Acceptance requires an authorized owner decision on this exact revision through the pull-request review path; see [Acceptance](#acceptance).
- **Type**: Architecture + Authorization + Delivery UX
- **Related Issues**: #4624 (delivered proposal); #4995 (tracking umbrella), #4996 (design acceptance), #4997–#4999 (implementation), #5000 (closeout)
- **Related RDRs**: [RDR-066](RDR-066-feature-intent-approval-lifecycle.md), [RDR-071](RDR-071-confidence-driven-issue-delivery.md), [RDR-077](RDR-077-automation-phases-and-work-item-authorization.md), [RDR-080](RDR-080-project-delegation-after-settled-intent.md)
- **Related intent**: `docs/intent/bounded-phase-authorization/`, `docs/intent/automation-phases/`, `docs/intent/auto-merge-strategy/`, `docs/intent/project-delegation/`, and `docs/intent/inbox-phase-relevance/`
- **Implementation status**: The narrower bounded-action foundation and
  deterministic boundary rechecks (`BOUNDED-PHASE-AUTHORIZATION-010`, `-011`,
  and `-004`) are checked in the linked EARS. The eight phase-lifecycle claims
  remain proposed and are tracked under #4995. No exclusive stop is accepted
  or enabled, and no project setting, including `auto_merge_mode`, changes.

## Acceptance

This RDR is Proposed. It becomes Accepted only when an authorized owner
reviews this exact revision and records an explicit decision on it through the
pull-request review path. Merging it, filing an implementation issue, or
approving an earlier revision is not acceptance. Until that decision exists:

- RDR-077's rule that no per-item override stops project automation beyond a
  chosen endpoint stays in force for ordinary continuation grants and project
  defaults.
- `BOUNDED-PHASE-AUTHORIZATION-001`–`-003` and `-005`–`-009` stay unchecked and
  unimplemented. `-010`, `-011`, and `-004` remain the only shipped
  bounded-authorization behavior.
- `automation_phases` stays default-off, and no surface mints, revokes, or
  consumes a bounded authorization.

Acceptance of this revision authorizes exactly three things: the narrow
RDR-077 exception recorded under [Prior-RDR impact](#prior-rdr-impact), the
implementation of the mapped claims behind the existing rollout guard, and the
LID handoff that makes the implementation issues eligible. It does not
authorize enabling `automation_phases`, changing any project's settings,
merging any pull request, or treating an existing GitHub approval, review,
agent run, or continuation grant as a bounded authorization.

## Decision required

Approve a separate explicit authorization action for a bounded delivery phase.
The action delegates execution within a precisely identified work lineage; it
does not attest that any commit has been reviewed and it is not derived from a
GitHub approval. On acceptance, this decision replaces RDR-077's prohibition
on a per-item stop only for the new authorization type. Existing continuation
grants and their endpoint behavior remain unchanged.

## Problem

Paid can continue a manually started work item through an endpoint, but that
endpoint is not a stopping boundary: independently enabled project automation
may continue it. That is unsuitable when an authorized user wants Paid to
finish review and repair for one PR but stop before merge, or finish a defined
coding phase and stop before the next phase. Conversely, a stale owner review
is evidence about an earlier head, not a delegation for future repairs or a
current-head review attestation.

## Prior-RDR impact

| Record | Effect of this proposal |
| --- | --- |
| RDR-077 | One narrow exception. An explicit bounded authorization may suppress automatic advancement of its own identified lineage into its stop-before phase. RDR-077's continuation grants keep their current additive, non-stopping behavior, including that revoking a grant restores project defaults. |
| RDR-080 | Unchanged. The project delegation posture stays a decision-delegation input. It never supplies execution authority, never mints a stop, and never refreshes review evidence. |
| RDR-066, RDR-071 | Unchanged. Feature approval and confidence-driven readiness stay independently authoritative. A bounded authorization neither grants nor waives either. |
| `auto-merge-strategy` intent | Unchanged. The fail-closed current-head review classifier stays the sole authority for whether a merge still needs a fresh review. A bounded authorization never refreshes, reconstructs, or waives one. |

## Proposed decision

### Identity and scope

An authorization names an **automation phase**, never a delivery milestone. The
phase vocabulary is `Automation::Phases` (`discovery`, `issue_preparation`,
`coding`, `merge`, `release_deployment`, `operations`); a project's own
milestone name is not an automation phase and is not an authorization scope.
Documentation work and implementation work in the same project each need their
own identified work item and authorization unless an explicitly supported,
reviewed scope later includes both. Mentioning the same milestone, parent,
dependency, or issue does not join their scopes.

The initial supported scope is one project, one issue or PR, its pinned
accepted intent/acceptance evidence, and the established issue → implementation
run → PR → review → repair lineage. That lineage is the one
`Automation::ContinuationGrantLookup` resolves: the work item, the pull
requests Paid opened for it, and — from a pull request back to its source
issue. Milestones, parent/child issue links, dependencies, mentions, and
unrelated PRs never extend it. New issues, child work, additional PRs,
milestone-wide delegation, release, deployment, and enabling settings require
separately supported, explicit authorization.

The authorization records the selected starting phase, the selected exclusive
stop boundary, permitted actions, author, tenant, creation and expiry times,
policy revision/signature, and intent evidence digest.

### Consent and review evidence

The user invokes a distinct **Authorize bounded phase** action. Before consent,
Inbox, work detail, chat, API, and tool surfaces show the exact work identity,
intent evidence, allowed actions, endpoint, effective stop, project defaults
that would otherwise continue, remaining CI/review/branch-protection checks,
invalidation conditions, expiry, and revocation effect.

The authorization permits execution; it never changes GitHub review state,
reconstructs stale approvals, or represents an old review as applying to the
current head. If merge is selected, Paid still requires all repository rules,
including explicitly required fresh reviews, to pass. If coding is selected,
the grant stops at merge-ready and does not imply merge authority.

### In-scope work and reassessment

Permitted actions are the selected phase's normal work and bounded review/CI/
conflict/repair iterations on the identified lineage. Deterministic controls
(tenant and actor authorization, feature flags, budgets, trusted inputs,
branch protection, required checks, and repository permissions) always apply.

Before admission, dequeue, retry, and every follow-up action, Paid verifies
record identity, lineage, status, expiry, revocation, selected boundary,
current policy signature, and deterministic controls. A semantic assessment of
whether a proposed repair corresponds to the pinned scope uses `agent_harness`
with bounded evidence and fails closed when unavailable, malformed, ambiguous,
or out of scope. It cannot waive deterministic policy.

The authorization pauses for an explicit visible reassessment/decision when
intent or acceptance scope expands, policy or permissions change, new risk is
found, or scope correspondence is unknown. A reassessment can continue only
the unchanged authorization, supersede it with newly consented scope, or stop
it. It cannot silently broaden the scope.

### Enforceable stopping and lifecycle

A bounded authorization has two separate effects on its one identified
lineage, and every lifecycle state resolves both explicitly:

| Effect | Meaning |
| --- | --- |
| Delegation | The selected action class may run on the identified lineage, even where project defaults for that phase are off. |
| Suppression | The lineage does not automatically advance into the authorization's stop-before phase, even where project defaults would continue that phase. |

The two effects differ in what withdraws them. An ordinary RDR-077
continuation grant is purely additive: it authorizes work and never stops it,
and revoking it restores project defaults. A bounded authorization is a
complete instrument for its lineage, so a terminal state withdraws both
effects for that lineage and never silently falls through to project defaults.

| State | Delegation effect | Suppression effect |
| --- | --- | --- |
| Active | The selected actions are admitted, subject to the deterministic controls that always apply. | The stop-before phase is not entered. |
| Completed | No new action. | The stop persists; reopening work does not reactivate it. |
| Revoked | No new action for the delegated actions. | The stop-before phase is not entered automatically. |
| Expired | No new action. | The stop-before phase is not entered automatically. |
| Reassessment required | Paused until an authorized actor resolves it. | Paused until an authorized actor resolves it. |
| Superseded | The superseded record neither authorizes nor constrains anything. | None; the boundary transfers to the superseding authorization. |

Recovery from a revoked, expired, or completed record is one explicit
authorized decision — a new explicit authorization, or an explicit return of
the lineage to ordinary project policy — recorded as the lineage's governing
decision. It is never a silent fall-through, and it never revives the
withdrawn record.

The selected boundary is exclusive: an active bounded authorization blocks
automatic advancement of its identified lineage into the next phase even when
project defaults permit that phase. It completes visibly when the selected
endpoint is reached, is not revived by reopening, and is inspectable,
auditable, revocable, and actor/tenant scoped. Revocation and completion are
serialized with admission so a dequeued or follow-up action cannot escape the
stop. Existing actions are not force-killed; no subsequent action begins after
the recheck fails.

This is a narrow exception to RDR-077's current "no per-item stop" rule. It
must compose with the existing phase policy and continuation grants rather than
introduce a parallel approval engine. Approval-gated and confidence-driven
admission policies remain independently authoritative; this authorization
adds neither a feature-design approval nor an issue-readiness exception.

## Reconciliation with the shipped foundation

`BOUNDED-PHASE-AUTHORIZATION-010`, `-011`, and `-004` are shipped and remain
the single authority for the behavior they describe. This proposal extends
them; it does not restate or replace them.

| Shipped claim | Shipped behavior | What this proposal adds |
| --- | --- | --- |
| `BOUNDED-PHASE-AUTHORIZATION-010` | `Automation::AuthorizeBoundedAction` is the single write boundary: it persists actor, action, expiry, pinned intent digest, acceptance references, stop-before phase, and an audit event in one transaction, and `Automation::RevokeBoundedAction` applies the same action-specific permission gate. | One phase-scoped consent projection that shows the selected phase, permitted actions, and effective stop before that write. No second write boundary. |
| `BOUNDED-PHASE-AUTHORIZATION-011` | Review and repair delegation use the run permission; merge delegation uses the stronger merge-delegation permission. Product decisions, feature approval, release, deployment, and setting enablement are never delegable delivery actions. | The same rule applied at consent time and shown on every surface. The proposal adds no delegable action class. |
| `BOUNDED-PHASE-AUTHORIZATION-004` | `Automation::DelegatedActionAdmission` and `Automation::DelegatedWorkBoundary` recheck tenant, authorization lifecycle, expiry, intent/acceptance/evidence revisions, posture signature, phase, phase policy, stop boundary, and deterministic repository controls before create, queue, dequeue, retry, follow-up, repair, and closeout, and fail closed into one focused decision. | The visible `bounded_phase_stop` result, the reassessment path, and the consent surfaces. The rechecks themselves are reused, not duplicated, and no second admission engine is introduced. |

The shipped rechecks already fail closed: a revoked, expired, or completed
record starts no new action and does not fall through to project defaults for
that delegated action on that lineage. The proposal's lifecycle table above
generalizes that rule to the stop-before phase so both effects of the
instrument resolve the same way.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| Treat a GitHub approval as ongoing delegation | Rejected: it confuses head-specific review evidence with execution authority. |
| Add a milestone-wide "Phase 2" switch | Rejected: milestone membership is too broad and changes independently of a work lineage. |
| Add a stop option to existing continuation grants | Rejected: it changes their established endpoint semantics and makes policy source ambiguous. |
| Let project defaults override the selected stop | Rejected: it defeats the reason for bounded authorization. |
| Allow coding authorization to imply merge | Rejected: merge has independent authority and repository requirements. |
| Give the bounded authorization its own approval engine | Rejected: `Automation::EffectivePolicy` remains the single effective-policy contract, and the existing admission rechecks are reused. |

## Implementation slices

| Claim | Slice | Issue |
| --- | --- | --- |
| `BOUNDED-PHASE-AUTHORIZATION-001` | Phase identity, lineage, and durable authorization record | #4997 |
| `BOUNDED-PHASE-AUTHORIZATION-002` | In-scope action enforcement on the identified lineage | #4997 |
| `BOUNDED-PHASE-AUTHORIZATION-003` | Exclusive stop composed with the effective policy | #4997 |
| `BOUNDED-PHASE-AUTHORIZATION-005` | Reassessment triggers, resolution, and resumption | #4998 |
| `BOUNDED-PHASE-AUTHORIZATION-006` | Bounded semantic scope assessment | #4998 |
| `BOUNDED-PHASE-AUTHORIZATION-007` | Merge and merge-ready gating | #4999 |
| `BOUNDED-PHASE-AUTHORIZATION-008` | One consent projection across Inbox, work detail, chat, API, and tools | #4999 |
| `BOUNDED-PHASE-AUTHORIZATION-009` | Terminal transitions and admission races | #4999 |
| Closeout audit | Criterion-level closeout against the accepted intent | #5000 |

Each slice writes failing-first tests that cite its EARS ID, then implements
the claim by extending the shipped `-010`/`-011`/`-004` foundation rather than
adding a parallel authority. The slices run the focused specs, `bin/lint`,
`bin/coherence-check.mjs`, and the required suite before any rollout decision.

## Rollout guard

RDR-077's `automation_phases` guard remains the required gate. It is defined
in `FeatureFlags::DEFINITIONS`, default off, and read through
`FeatureFlags.enabled?(:automation_phases, project:)` by
`Automation::RolloutGuard`. The authorized project feature-flag management
surface is the enablement surface. This proposal does not authorize enabling
it, changing any project's settings, or merging any pull request. A future
accepted implementation must add a named enablement surface and keep it
disabled until all execution paths and concurrency checks pass.
