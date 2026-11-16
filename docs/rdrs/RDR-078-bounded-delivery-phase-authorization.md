# RDR-078: Bounded Delivery-Phase Authorization

## Metadata

- **Date**: 2026-10-24
- **Status**: Final
- **Acceptance**: The owner accepted the HLD, RDR, LLD, and EARS design blobs at
  PR #5109 head `a3e4c658679218019e89355afc89db28e597dcff`, recorded in
  [#4996's owner decision](https://github.com/viamin/paid/issues/4996#issuecomment-6908815294).
  A later PR commit changed only the CI workflow; the accepted design blobs
  remained identical. This decision does not itself authorize runtime use.
- **Type**: Architecture + Authorization + Delivery UX
- **Related Issues**: #4624 (delivered proposal); #4995 (tracking umbrella), #4996 (design acceptance), #4997–#4999 (implementation), #5000 (closeout)
- **Related RDRs**: [RDR-066](RDR-066-feature-intent-approval-lifecycle.md), [RDR-071](RDR-071-confidence-driven-issue-delivery.md), and [RDR-077](RDR-077-automation-phases-and-work-item-authorization.md)
- **Related intent**: `docs/intent/bounded-phase-authorization/`, `docs/intent/automation-phases/`, `docs/intent/auto-merge-strategy/`, and `docs/intent/inbox-phase-relevance/`
- **Implementation status**: The narrower bounded-action foundation and
  deterministic boundary rechecks (`BOUNDED-PHASE-AUTHORIZATION-010`, `-011`,
  and `-004`) are checked in the linked EARS. The eight phase-lifecycle claims
  are accepted implementation gaps tracked under #4995. No exclusive stop is
  implemented or enabled; approval freshness and project settings, including
  Forager's `auto_merge_mode`, remain unchanged.

## Acceptance boundary

The owner decision linked above accepts the exact HLD, RDR, LLD, and EARS
blobs. A GitHub approval, PR review, run, continuation grant, issue
relationship, or milestone membership does not mint a bounded authorization.
The RDR-077 exception takes effect only when the accepted phase lifecycle is
implemented and separately enabled; until then, RDR-077's runtime grant rules
remain unchanged and `automation_phases` remains default-off.

## Decision

The accepted design adds a separate explicit authorization action for a bounded
delivery phase.
The action delegates execution within a precisely identified work lineage; it
does not attest that any commit has been reviewed and it is not derived from a
GitHub approval. When implemented and enabled, this decision narrows RDR-077's
prohibition on a per-item stop only for the new authorization type. Existing
continuation grants and their endpoint behavior remain unchanged.

## Problem

Paid can currently continue a manually started work item through an endpoint,
but that endpoint is not a stopping boundary: independently enabled project
automation may continue it. That is unsuitable when an authorized user wants
Paid to finish review and repair for one PR but stop before merge, or finish a
defined coding phase and stop before the next phase. Conversely, a stale owner
review is evidence about an earlier head, not a delegation for future repairs
or a current-head review attestation.

## Accepted direction

### Project policy is the default

Without a bounded authorization for the identified lineage, Paid follows the
project's existing phase and merge policy. A project configured for fully
automatic delivery may merge a qualifying PR after its configured CI, review,
security, branch-protection, dependency, and mergeability checks; this decision
adds no per-PR human checkpoint to that path. The authorization action is an
explicit per-work choice to delegate a narrower phase and enforce a stop.
The consent surface defaults to **inherit project policy** and creates no
bounded authorization until an authorized user selects and confirms that
exception. An independent human-only review hold remains authoritative.

Once a stop is selected, even a fully automatic project cannot silently cross
it. The user can explicitly return the lineage to ordinary project policy or
authorize a new scope; expiry or revocation alone never converts a stopped
lineage into an automatic merge. Paid continues ordinary in-scope review and
repair without asking at every step. The bounded authorization asks for new
consent when the original consent cannot be shown to cover the next action;
repository-required human review remains a separate gate.

### Project policy is the default

Without a bounded authorization for the identified lineage, Paid follows the
project's existing phase and merge policy. A project configured for fully
automatic delivery may merge a qualifying PR after its configured CI, review,
security, branch-protection, dependency, and mergeability checks; this proposal
adds no per-PR human checkpoint to that path. The authorization action is an
explicit per-work choice to delegate a narrower phase and enforce a stop.
The consent surface defaults to **inherit project policy** and creates no
bounded authorization until an authorized user selects and confirms that
exception. An independent human-only review hold remains authoritative.

Once a stop is selected, even a fully automatic project cannot silently cross
it. The user can explicitly return the lineage to ordinary project policy or
authorize a new scope; expiry or revocation alone never converts a stopped
lineage into an automatic merge. Paid continues ordinary in-scope review and
repair without asking at every step. The bounded authorization asks for new
consent when the original consent cannot be shown to cover the next action;
repository-required human review remains a separate gate.

### Identity and scope

An authorization names an **automation phase**, never a delivery milestone.
Forager's “Phase 2” is a project milestone and is not an authorization scope.
PR #20 documentation work and PR #21 implementation work each need their own
identified work item/PR and authorization unless an explicitly supported,
reviewed scope later includes both. Mentioning the same milestone, parent,
dependency, or issue does not join their scopes.

The initial supported scope is one project, one issue or PR, its pinned
accepted intent/acceptance evidence, and the established same-work issue →
implementation run → PR → review → repair lineage. It records the selected
starting phase,
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

The authorization has two independent effects: it delegates the selected
actions and it suppresses automatic advancement into its selected stop-before
phase. The stop is exclusive while the authorization is active: project
defaults and an ordinary continuation grant cannot advance its identified
lineage across that boundary. Completion leaves the stop in place, and
reopening does not reactivate the authorization. Expiry and reassessment fail
closed to a visible decision. Revocation stops new delegated actions and keeps
the lineage from automatically entering the suppressed phase. Recovery from
those terminal states requires either a new explicit authorization or an
explicit, authorized decision to return the lineage to ordinary project policy;
it is never a silent fall-through. Supersession transfers both effects to the
newer authorization. Each transition is inspectable, auditable, actor/tenant
scoped, and serialized with admission so a dequeued or follow-up action cannot
escape the boundary. Existing actions are not force-killed; no subsequent
action begins after the recheck fails.

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

1. **#4997 (`-001`–`-003`)** extends the shipped action-specific record and
   shared admission recheck (`-010`, `-011`, and `-004`) with phase identity,
   same-work lineage, and exclusive-stop composition. It adds no second action
   authorization source.
2. **#4998 (`-005`–`-006`)** adds reassessment and bounded semantic scope
   assessment to that same lifecycle and admission boundary.
3. **#4999 (`-007`–`-009`)** provides the shared consent projection and command
   service for Inbox, work detail, chat, API, and MCP/tool paths; it completes
   fresh-review gates and terminal-race handling.
4. **#5000** maps every claim to shipped code and test assertions before any
   implementation-complete status or rollout decision.
5. Keep `automation_phases` default-off and do not expose the action until all
   enforcement paths are behind the RDR-077 rollout guard. No migration grants
   authority from existing reviews, runs, or continuation grants.
6. Write tests first for the EARS below, then implement; run the focused specs,
   `bin/lint`, `bin/coherence-check.mjs`, and the required suite before any
   rollout decision.

## Rollout guard

RDR-077's `automation_phases` guard remains the required gate. This decision
does not authorize enabling it, changing Forager settings, or merging PR #20
or #21. Implementation must add a named enablement surface
and keep it disabled until all execution paths and concurrency checks pass.

## Finalization record

- **Contradictions resolved:** RDR-077's continuation grant has no stopping
  power, while this decision needs an exclusive stop for one identified
  lineage. The new authorization type alone supplies that exception; existing
  grants keep their endpoint behavior. The HLD, owning LLD, and EARS now state
  that fully automatic project policy remains the ordinary default, and only
  an explicitly selected bounded stop overrides it.
- **Load-bearing assumptions:** The shipped action-specific authorization
  record and shared admission recheck (`-010`, `-011`, `-004`) provide a single
  authority path and fail-closed action boundaries; their checked EARS and
  linked tests are the current evidence. The accepted LLD maps same-work
  lineage and policy-signature checks onto those boundaries, so no second
  authorization source is required by the design. #4997 and #5000 must prove
  the implementation actually enforces the exclusive stop at every boundary.
  If it cannot, keep the guard off and revise the decision. The accepted EARS
  require semantic scope assessment through `agent_harness` to fail closed;
  #4998 must demonstrate that behavior before rollout.
- **Decisive proof:** #4997–#4999 implement the unchecked EARS claims with
  failing-first tests for enabled project defaults, lineage isolation,
  authorization transitions, stale reviews, and admission races. #5000 maps
  each claim to shipped code and tests. This is the minimum proof for the
  selected same-work boundary; no broader milestone or release scope is
  claimed. The devcontainer is the available production-like acceptance
  environment until a deployment exists.
- **Cross-record effect:** RDR-077 retains ordinary phase settings and
  additive continuation grants; RDR-078 alone owns the accepted narrow
  exclusive-stop exception, designed in the bounded-phase LLD. RDR-080's
  project posture remains an input to effective policy and cannot overrule a
  selected RDR-078 stop. Neither RDR-066 approval nor RDR-071 issue readiness
  is changed. The HLD owns the platform authority boundary; the LLD and EARS
  own the lifecycle and observable behavior.
- **Proportionality and follow-up:** Because this changes authorization across
  phase, review, and merge paths, the owner reviewed the exact artifact blobs,
  and implementation remains gated by criterion-level closeout and default-off
  rollout. The RDR leaves component mechanics and test assertions to the LLD
  and EARS. After a guarded pilot has processed meaningful bounded lineages,
  compare stops, reassessments, and attempted boundary crossings with this
  decision in a plan-versus-reality post-mortem; record surprises in #5000 or
  a focused follow-up issue.
