# RDR-078: Bounded Delivery-Phase Authorization

## Metadata

- **Date**: 2026-10-24
- **Status**: Proposed
- **Type**: Architecture + Authorization + Delivery UX
- **Related RDRs**: [RDR-066](RDR-066-feature-intent-approval-lifecycle.md), [RDR-071](RDR-071-confidence-driven-issue-delivery.md), and [RDR-077](RDR-077-automation-phases-and-work-item-authorization.md)
- **Related intent**: `docs/intent/bounded-phase-authorization/`, `docs/intent/automation-phases/`, `docs/intent/auto-merge-strategy/`, and `docs/intent/inbox-phase-relevance/`
- **Implementation status**: Design proposal only. It changes neither approval freshness nor any project setting, including Forager's `auto_merge_mode`.

## Decision required

Approve a separate explicit authorization action for a bounded delivery phase.
The action delegates execution within a precisely identified work lineage; it
does not attest that any commit has been reviewed and it is not derived from a
GitHub approval. On acceptance, this decision replaces RDR-077's prohibition
on a per-item stop only for the new authorization type. Existing continuation
grants and their endpoint behavior remain unchanged.

## Problem

Paid can currently continue a manually started work item through an endpoint,
but that endpoint is not a stopping boundary: independently enabled project
automation may continue it. That is unsuitable when an authorized user wants
Paid to finish review and repair for one PR but stop before merge, or finish a
defined coding phase and stop before the next phase. Conversely, a stale owner
review is evidence about an earlier head, not a delegation for future repairs
or a current-head review attestation.

## Proposed decision

### Identity and scope

An authorization names an **automation phase**, never a delivery milestone.
Forager's “Phase 2” is a project milestone and is not an authorization scope.
PR #20 documentation work and PR #21 implementation work each need their own
identified work item/PR and authorization unless an explicitly supported,
reviewed scope later includes both. Mentioning the same milestone, parent,
dependency, or issue does not join their scopes.

The initial supported scope is one project, one issue or PR, its pinned
accepted intent/acceptance evidence, and the established issue → implementation
run → PR → review → repair lineage. It records the selected starting phase,
the selected exclusive stop boundary, permitted actions, author, tenant,
creation and expiry times, policy revision/signature, and intent evidence
digest. New issues, child work, additional PRs, milestone-wide delegation,
release, deployment, and enabling settings require separately supported,
explicit authorization.

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

The selected boundary is exclusive: an active bounded authorization blocks
automatic advancement of its identified lineage into the next phase even when
project defaults permit that phase. It completes visibly when the selected
endpoint is reached, is not revived by reopening, and is inspectable,
auditable, revocable, and actor/tenant scoped. Revocation and completion are
serialized with admission so a dequeued or follow-up action cannot escape the
stop. Existing actions are not force-killed; no subsequent action begins after
the recheck fails.

This is a narrow exception to RDR-077's current “no per-item stop” rule. It
must compose with the existing phase policy and continuation grants rather than
introducing a parallel approval engine. Approval-gated and confidence-driven
admission policies remain independently authoritative; this authorization
adds neither a feature-design approval nor an issue-readiness exception.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| Treat a GitHub approval as ongoing delegation | Rejected: it confuses head-specific review evidence with execution authority. |
| Add a milestone-wide “Phase 2” switch | Rejected initially: milestone membership is too broad and changes independently of a work lineage. |
| Add a stop option to existing continuation grants | Rejected: it changes their established endpoint semantics and makes policy source ambiguous. |
| Let project defaults override the selected stop | Rejected: it defeats the reason for bounded authorization. |
| Allow coding authorization to imply merge | Rejected: merge has independent authority and repository requirements. |

## Focused implementation and validation plan

1. Add a tenant-scoped durable authorization record and immutable audit events;
   reference existing phase/lineage records rather than duplicating them.
2. Add one composition layer to `Automation::EffectivePolicy` and the existing
   continuation lookup; no path may evaluate a separate approval engine.
3. Implement authorized Inbox/work-detail/chat/API/tool actions through one
   command service and one consent projection.
4. Enforce admission, dequeue, retry, and follow-up rechecks with locking or
   compare-and-transition semantics; make completion, revocation, expiry, and
   reassessment visible states.
5. Keep `automation_phases` default-off and do not expose the action until all
   enforcement paths are behind the RDR-077 rollout guard. No migration grants
   authority from existing reviews, runs, or continuation grants.
6. Write tests first for the EARS below, then implement; run the focused specs,
   `bin/lint`, `bin/coherence-check.mjs`, and the required suite before any
   rollout decision.

## Rollout guard

RDR-077's `automation_phases` guard remains the required gate. This proposal
does not authorize enabling it, changing Forager settings, or merging PR #20
or #21. A future accepted implementation must add a named enablement surface
and keep it disabled until all execution paths and concurrency checks pass.
