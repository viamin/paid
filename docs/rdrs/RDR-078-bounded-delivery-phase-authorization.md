# RDR-078: Bounded Delivery-Phase Authorization

## Metadata

- **Date**: 2026-10-24
- **Status**: Proposed
- **Acceptance**: Owner acceptance of this exact revision is a human-only
  decision through the #4996 review path. The delivering PR must carry the
  structured `paid-hold-review` hold; only the owner releasing that hold may
  change this RDR's status and make the scoped RDR-077 amendment effective.
- **Type**: Architecture + Authorization + Delivery UX
- **Related Issues**: #4624 (delivered proposal); #4995 (tracking umbrella), #4996 (design acceptance), #4997–#4999 (implementation), #5000 (closeout)
- **Related RDRs**: [RDR-066](RDR-066-feature-intent-approval-lifecycle.md), [RDR-071](RDR-071-confidence-driven-issue-delivery.md), [RDR-077](RDR-077-automation-phases-and-work-item-authorization.md), and [RDR-080](RDR-080-project-delegation-after-settled-intent.md)
- **Related intent**: `docs/intent/bounded-phase-authorization/`, `docs/intent/automation-phases/`, `docs/intent/auto-merge-strategy/`, and `docs/intent/inbox-phase-relevance/`
- **Implementation status**: This revision is the reviewable proposed design.
  The narrower bounded-action
  foundation and deterministic boundary rechecks
  (`BOUNDED-PHASE-AUTHORIZATION-010`, `-011`, and `-004`) are checked in the
  linked EARS. The eight phase-lifecycle claims remain implementation gaps
  tracked under #4995: #4997 (`-001`–`-003`), #4998 (`-005`–`-006`), #4999
  (`-007`–`-009`). No exclusive stop is enabled; approval freshness and
  project settings, including every project's `auto_merge_mode`, remain
  unchanged.

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

## Decision

### Identity and scope

An authorization names an **automation phase**, never a delivery milestone.
A project's “Phase 2” is a milestone, not an authorization scope.
Documentation work and implementation work each need their own identified
work item/PR and authorization unless an explicitly supported, reviewed scope
later includes both. Mentioning the same milestone, parent, dependency, or
issue does not join their scopes.

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

The selected boundary is exclusive: a bounded authorization blocks automatic
advancement of its identified lineage into its stop-before phase even when
project defaults, a continuation grant covering that endpoint, or any other
independently enabled automation would permit that phase. The stop is a
visible `bounded_phase_stop` decision naming the governing authorization.

An authorization has two separate effects on its one identified lineage: it
delegates the selected phase's actions, and it suppresses automatic advancement
into its stop-before phase. Every lifecycle state below resolves both effects
explicitly, so withdrawing the delegation never silently releases the
suppression, and suppressing a phase never silently withdraws the delegation.

Lifecycle resolves the stop as follows:

- **Active or reassessment-paused** — the stop holds for the identified
  lineage. Reassessment pauses work; it never silently releases the stop.
- **Completed at its endpoint** — completion is visible, reopening does not
  revive the authorization, and the stop persists: entering the stop-before
  phase still requires a new explicit authorization for that lineage.
- **Expired** — admission fails closed to a visible reassessment decision; no
  new action starts and the lineage does not silently advance past the stop
  until an authorized actor resolves it.
- **Stopped through reassessment** — an authorized actor resolved a
  reassessment by stopping the authorization; the stop holds and the lineage
  remains parked until a later explicit authorization or an explicit return
  to ordinary project policy.
- **Revoked** — the instrument is withdrawn and the lineage fails closed: the
  delegated actions it covered start no new action
  (`BOUNDED-PHASE-AUTHORIZATION-004`), and the suppressed stop-before phase is
  not entered automatically. Withdrawing an instrument that both delegates and
  suppresses must never silently broaden authority, so — unlike RDR-077's
  purely additive grants, whose revocation restores project defaults —
  revocation routes one visible decision naming the recovery paths: a new
  explicit authorization or an explicit return of the lineage to ordinary
  project policy. Each recovery path is an explicit authorized act recorded as
  the lineage's governing decision, so recovery never depends on a silent
  fall-through to project defaults. Consent and revocation surfaces show this
  effect before the action.
- **Superseded** — the newer explicit authorization governs the lineage and
  its boundary; the superseded instrument neither authorizes nor constrains
  anything.

Completion, revocation, and reassessment are serialized with admission so a
dequeued or follow-up action cannot escape the stop. Existing actions are not
force-killed; no subsequent action begins after the recheck fails.

This is a narrow exception to RDR-077's current “no per-item stop” rule,
scoped to this authorization type. It composes with the existing phase policy
and continuation grants rather than introducing a parallel approval engine:
the bounded stop outranks a continuation grant's endpoint for its identified
lineage only, and never disables a grant, a project setting, or automation for
any other lineage. Approval-gated and confidence-driven admission policies
remain independently authoritative; this authorization adds neither a
feature-design approval nor an issue-readiness exception.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| Treat a GitHub approval as ongoing delegation | Rejected: it confuses head-specific review evidence with execution authority. |
| Add a milestone-wide “Phase 2” switch | Rejected initially: milestone membership is too broad and changes independently of a work lineage. |
| Add a stop option to existing continuation grants | Rejected: it changes their established endpoint semantics and makes policy source ambiguous. |
| Let project defaults override the selected stop | Rejected: it defeats the reason for bounded authorization. |
| Release the stop on revocation, mirroring grant revocation | Rejected: a bounded instrument delegates and suppresses; withdrawal must not silently release the automation it suppressed. Recovery is one explicit decision. |
| Allow coding authorization to imply merge | Rejected: merge has independent authority and repository requirements. |

## Focused implementation and validation plan

The proposed revision maps the eight phase-lifecycle claims to focused,
independently verifiable slices:

| Slice | Claims | Content |
| --- | --- | --- |
| #4997 | `-001`–`-003` | Phase-lifecycle identity, same-work lineage, and exclusive stop composed through `Automation::EffectivePolicy` and the existing continuation lookup. |
| #4998 | `-005`–`-006` | Reassessment lifecycle and bounded `agent_harness` scope assessment with fail-closed semantics. |
| #4999 | `-007`–`-009` | One consent projection across Inbox/work-detail/chat/API/tool surfaces, merge gates, and terminal-transition races. |
| #5000 | closeout | Evidence-based audit of every claim in this RDR against shipped code, tests, and docs. |

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

RDR-077's `automation_phases` guard remains the required gate. This decision
does not authorize enabling it or changing any project's settings, and no
existing GitHub approval or review gains authority from it. Implementation
must add a named enablement surface and keep it disabled until all execution
paths and concurrency checks pass. The shipped
`BOUNDED-PHASE-AUTHORIZATION-010`, `-011`, and `-004` foundation is inert by
construction: no user-facing surface creates authorizations, admission only
rechecks records that already exist, and no GitHub approval, run, or
continuation grant mints one.

## Acceptance required

This revision is ready for owner acceptance through the #4996 review path. The
delivering PR must carry the structured `paid-hold-review` hold, and only the
owner releasing that hold may make the status change and RDR-077 amendment
effective. The review reconciles the design against RDR-077, RDR-080, the HLD,
the shipped implementation, and the unchecked EARS claims:

- **RDR-077 exclusive-stop exception resolved.** The stop belongs only to
  this authorization type. Continuation grants, project phase settings,
  activation labels, and manual-start endpoints keep RDR-077's non-stopping
  endpoint semantics; `AUTOMATION-PHASES-012` remains in force for those
  surfaces, rescoped to make that explicit. Terminal lifecycle semantics are
  recorded under [Enforceable stopping and
  lifecycle](#enforceable-stopping-and-lifecycle): the stop persists after
  completion and after a reassessment stop, fails closed on expiry and on
  revocation — withdrawal never silently releases the automation the
  instrument suppressed, unlike RDR-077's purely additive grants, whose
  revocation restores project defaults — and transfers to the superseding
  instrument on supersession. The revoked case reuses the shipped
  `BOUNDED-PHASE-AUTHORIZATION-004` fail-closed lifecycle instead of adding a
  second admission rule, and recovery is one explicit authorized decision
  rather than a silent fall-through to project defaults.
- **RDR-080 consistency.** RDR-080's posture remains a decision-delegation
  input; execution authority for an admitted lineage stays with the RDR-077
  phase policy and this authorization, and this authorization remains the
  only per-lineage exclusive stop.
- **Shipped foundation reused, not duplicated.** The durable
  `BoundedDelegatedAction` record (`-010`/`-011`), its write boundaries
  (`Automation::AuthorizeBoundedAction`/`RevokeBoundedAction`), and the
  shared admission contract (`Automation::DelegatedActionAdmission` +
  `Automation::DelegatedWorkBoundary`, `-004`) are the single authority.
  `-001`–`-003` and `-005`–`-009` extend those contracts; no parallel
  authorization record, approval engine, or admission path may be added.
- **Cross-segment vocabulary fixed.** Phase identity comes from
  `Automation::Phases`; same-work lineage from
  `Automation::ContinuationGrantLookup`'s chain; review freshness stays owned
  by the existing merge policy (`docs/intent/auto-merge-strategy/`) — this
  authorization never refreshes a stale approval; reassessment and semantic
  scope correspondence are owned by this segment.
- **Rollout guard unchanged.** `automation_phases` stays default-off; no
  existing GitHub approval, review, run, or continuation grant grants this
  authority, and no authorized user surface creates it yet.

Implementation slices #4997–#4999 and closeout #5000 track the remaining
claims under umbrella #4995.
