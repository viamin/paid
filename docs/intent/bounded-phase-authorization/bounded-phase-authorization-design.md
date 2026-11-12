---
parent: PAID
prefix: BOUNDED-PHASE-AUTHORIZATION
---

# Low-Level Design: Bounded Delivery-Phase Authorization

Implements proposed [RDR-078](../../rdrs/RDR-078-bounded-delivery-phase-authorization.md).

## Boundary

`BoundedPhaseAuthorization` is a proposed execution delegation, not a pull
request review record. Its identity is `(account, project, root work item,
selected phase, stop-before phase, intent digest)`. The root work item is one
identified issue or PR; `Automation::ContinuationGrantLookup` supplies only
the existing same-work lineage. Milestones, parent/child issue links,
dependencies, mentions, and unrelated PRs never extend it.

Phase identity comes from `Automation::Phases`, and the delivery phase of each
delegated action class comes from `Automation::DelegatedActionAdmission`'s
`ACTION_PHASES` and `STOP_BEFORE_PHASES`: review and repair execute in coding
and stop before merge, and merge executes in merge and stops before release
and deployment. A project's own milestone name is not a phase and is not an
authorization scope.

The shipped implementation is the action-specific durable
`BoundedDelegatedAction` contract. It records bounded evidence and an
account-activity audit event before later admission and lifecycle enforcement
composes it with `Automation::EffectivePolicy`. Authorization and revocation
are service write boundaries (`Automation::AuthorizeBoundedAction`,
`Automation::RevokeBoundedAction`) that delegate permission checks to the
project policy; the model stays validation-only.

The authorization stores its author, consent projection, permitted actions,
intent/acceptance references, policy signature, lifecycle timestamps, and
audit references. All records use project/account tenant scoping and normal
actor policy checks. Expiry, completion, revocation, and superseded are
terminal for admission until a new explicit authorization. Reassessment-
required pauses admission until an authorized actor resolves it by stopping,
superseding, or resuming the unchanged authorization.

## Shipped foundation

These behaviors are implemented and are the authority for what they state.
The remaining claims extend them and never restate them.

| Shipped claim | Component | Behavior |
| --- | --- | --- |
| `BOUNDED-PHASE-AUTHORIZATION-010` | `Automation::AuthorizeBoundedAction`, `Automation::RevokeBoundedAction`, `BoundedDelegatedAction` | One write boundary that requires an identified issue in the same project and account, a pinned `sha256:` intent digest matching the work item's current intent, acceptance references, and the action's stop-before phase; it persists actor, action, expiry, and canonical evidence and records the audit event in the same transaction. Revocation passes the same action-specific permission gate and records its account-activity event in the same transaction. |
| `BOUNDED-PHASE-AUTHORIZATION-011` | `BoundedDelegatedAction::ACTIONS`, `BoundedDelegatedAction::RESERVED_ACTIONS`, `ProjectPolicy#delegate_bounded_action?` | Review and repair use the run permission; merge uses the stronger merge-delegation permission. Product decisions, feature approval, release, deployment, and setting enablement are reserved and never delegable. |
| `BOUNDED-PHASE-AUTHORIZATION-004` | `Automation::DelegatedActionAdmission`, `Automation::DelegatedWorkBoundary` | Before create, queue, dequeue, retry, follow-up, repair, and closeout, the admission rechecks tenant scope, authorization lifecycle, expiry, intent/acceptance/evidence revisions, posture signature, phase, phase policy, the stop boundary, and the deterministic controls (security, trust, budget, repository controls, assessment availability). Any mismatch fails closed into one focused Inbox decision; a revoked, completed, or expired record starts no new action and never falls through to project defaults for that lineage. |

## Policy composition

`Automation::EffectivePolicy` remains the sole execution-policy result. Its
bounded-authorization input has three outcomes:

| Outcome | Effective policy result |
| --- | --- |
| The action is in the selected phase and the authorization is current | Permit as `:bounded_phase_authorization`, then apply existing controls. |
| The action crosses the selected stop boundary on its lineage | Block as `:bounded_phase_stop`, even if project defaults permit it. |
| The authorization is revoked, expired, invalid, unknown, or outside scope | Block or require reassessment; never fall through to project defaults for that lineage. |

The boundary override is deliberately limited to this explicit authorization.
Ordinary RDR-077 continuation grants preserve their existing behavior, where
project defaults can continue after their endpoint.

An authorization has two separate effects on its one lineage, and every
lifecycle state resolves both:

| State | Delegation | Suppression |
| --- | --- | --- |
| Active | The selected action class is admitted, subject to the deterministic controls that always apply. | The stop-before phase is not entered. |
| Completed | No new action. | The stop persists; reopening does not reactivate it. |
| Revoked | No new action for the delegated actions. | The stop-before phase is not entered automatically. |
| Expired | No new action. | The stop-before phase is not entered automatically. |
| Reassessment required | Paused until an authorized actor resolves it. | Paused until an authorized actor resolves it. |
| Superseded | Neither authorizes nor constrains anything. | The boundary transfers to the superseding authorization. |

This differs from an ordinary continuation grant, which is additive and
non-stopping: revoking a grant restores project defaults, while a terminal
bounded authorization fails closed for its lineage. Recovery from a terminal
record is one explicit authorized decision — a new explicit authorization, or
an explicit return of the lineage to ordinary project policy — recorded as the
lineage's governing decision. It is never a silent fall-through.

## Scope assessment and invalidation

Structural checks compare project, tenant, work identity, lineage, phase,
endpoint, lifecycle, policy signature, and deterministic guards. Scope meaning
is assessed by a dedicated `agent_harness` request that receives the pinned
intent/acceptance evidence and proposed repair evidence and returns a bounded
schema: `in_scope`, `out_of_scope`, or `unknown`, with evidence references.
Unavailable or malformed output is `unknown` and fails closed.

An intent digest change, acceptance expansion, permission/policy change, new
risk, or `unknown`/`out_of_scope` correspondence transitions the authorization
to `reassessment_required` under lock and emits an Inbox decision. Only an
authorized actor can resolve it, by stopping the authorization, superseding it
with a newly consented authorization, or resuming the unchanged authorization
when the triggering condition resolved without scope expansion — for example a
policy change that was restored. Resumption transitions back to `active` under
the same lock after re-verifying policy signature, lineage, and expiry, emits
an audit event, and never edits the pinned scope; a resumed authorization is
re-evaluated if any trigger recurs. No semantic result bypasses deterministic
enforcement.

## Admission and concurrency

The shared admission service is called when an action is created, dequeued,
retried, and scheduled as a review/repair follow-up. It locks the authorization
or uses a conditional state transition that includes its lifecycle version.
Completion/revocation/reassessment take the same lock. A worker that loses the
race records a blocked outcome and starts no new action. Running work is not
force-killed, but its next externally visible or queued action rechecks.

The shipped `Automation::DelegatedWorkBoundary` already enforces this
serialization for the delegated action classes it knows. The proposed claims
extend the same lock and conditional transition to the phase-level lifecycle,
so the stop cannot be escaped by a dequeue or a follow-up that starts between
the terminal transition and the next boundary.

## Consent and surface parity

`BoundedPhaseAuthorizations::Plan` is the one contract for Inbox, work detail,
chat, REST API, and MCP/tool invocation. It exposes the work identity and
lineage, phase versus milestone explanation, selected actions and stop,
current authorization state, project-default continuation it suppresses,
remaining repository checks, invalidators, expiry, and revocation consequences.
The write command requires explicit confirmation and delegates permission
checks to the project policy. Read projections use the same policy decision so
the surfaces cannot disagree.

Review freshness is not decided here. The fail-closed current-head review
classifier in `docs/intent/auto-merge-strategy/` remains the sole authority
for whether a merge still needs a fresh review; the consent projection reports
its current result and never refreshes, reconstructs, or waives it.

## Merge, releases, and existing policies

Coding ends at merge-ready. Selecting merge is a separate delegate-able action
and permits an attempt only after existing checks, branch protection, security,
and required fresh reviews succeed. Neither selection authorizes release or
deployment. Feature approval, confidence-driven readiness, and RDR-077 phase
settings/grants remain conditions evaluated by the shared policy, not copied
into this record.

## Rollout guard

The phase model stays behind `Automation::RolloutGuard`, which reads the
default-off `automation_phases` flag through `FeatureFlags.enabled?`. This
segment adds no enablement surface of its own and does not authorize enabling
the flag, changing project settings, or merging any pull request.

## Test-first implementation slices

1. Model/audit/policy unit specs establish scope, lineage non-inheritance,
   lifecycle, revocation, expiry, reassessment resolution (stop, supersede,
   resume unchanged), and endpoint race behavior.
2. Effective-policy and queue specs establish exclusive stopping despite
   enabled downstream defaults and admission/dequeue/follow-up rechecks.
3. Scope-assessment specs establish bounded `agent_harness` input and fail-
   closed malformed, unavailable, unknown, and out-of-scope outcomes.
4. Request, Inbox, chat, API, and MCP specs establish identical consent and
   status projections, actor/tenant isolation, and repository-review blockers.
5. Integration specs cover completion/reopening and no implicit release,
   deployment, child-work, or setting-enable authority.

| Slice | Claims | Issue |
| --- | --- | --- |
| P01 | `BOUNDED-PHASE-AUTHORIZATION-001`, `-002`, `-003` | #4997 |
| P02 | `BOUNDED-PHASE-AUTHORIZATION-005`, `-006` | #4998 |
| P03 | `BOUNDED-PHASE-AUTHORIZATION-007`, `-008`, `-009` | #4999 |
| Closeout audit | Every claim of this segment | #5000 |

Each slice writes failing-first tests that cite its EARS ID, extends the
shipped `-010`/`-011`/`-004` foundation rather than adding a parallel
authority, and keeps `automation_phases` default-off.
