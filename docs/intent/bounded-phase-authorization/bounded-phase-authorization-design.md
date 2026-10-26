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

The authorization stores its author, consent projection, permitted actions,
intent/acceptance references, policy signature, lifecycle timestamps, and
audit references. All records use project/account tenant scoping and normal
actor policy checks. Expiry, completion, revocation, and superseded are
terminal for admission until a new explicit authorization. Reassessment-
required pauses admission until an authorized actor resolves it by stopping,
superseding, or resuming the unchanged authorization.

## Policy composition

`Automation::EffectivePolicy` remains the sole execution-policy result. Its
proposed bounded-authorization input has three outcomes:

| Outcome | Effective policy result |
| --- | --- |
| The action is in the selected phase and the authorization is current | Permit as `:bounded_phase_authorization`, then apply existing controls. |
| The action crosses the selected stop boundary on its lineage | Block as `:bounded_phase_stop`, even if project defaults permit it. |
| The authorization is revoked, expired, invalid, unknown, or outside scope | Block or require reassessment; never fall through to project defaults for that lineage. |

The boundary override is deliberately limited to this explicit authorization.
Ordinary RDR-077 continuation grants preserve their existing behavior, where
project defaults can continue after their endpoint.

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

## Consent and surface parity

`BoundedPhaseAuthorizations::Plan` is the one contract for Inbox, work detail,
chat, REST API, and MCP/tool invocation. It exposes the work identity and
lineage, phase versus milestone explanation, selected actions and stop,
current authorization state, project-default continuation it suppresses,
remaining repository checks, invalidators, expiry, and revocation consequences.
The write command requires explicit confirmation and delegates permission
checks to the project policy. Read projections use the same policy decision so
the surfaces cannot disagree.

## Merge, releases, and existing policies

Coding ends at merge-ready. Selecting merge is a separate delegate-able action
and permits an attempt only after existing checks, branch protection, security,
and required fresh reviews succeed. Neither selection authorizes release or
deployment. Feature approval, confidence-driven readiness, and RDR-077 phase
settings/grants remain conditions evaluated by the shared policy, not copied
into this record.

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
