---
parent: PAID
prefix: BOUNDED-PHASE-AUTHORIZATION
---

# Low-Level Design: Bounded Delivery-Phase Authorization

Implements accepted [RDR-078](../../rdrs/RDR-078-bounded-delivery-phase-authorization.md)
(design accepted 2026-11-11 under #4996).

## Boundary

The bounded phase authorization is the durable `BoundedDelegatedAction`
record family — execution delegation only, never a pull request review
record. Its identity is `(account, project, root work item, delegated action,
pinned intent digest and acceptance evidence, stop-before phase)`. The root
work item is one identified issue or PR; PR-rooted work resolves through
`Automation::DelegatedActionAdmission.work_item_for`. The same-work lineage
is exactly the chain `Automation::ContinuationGrantLookup` already resolves
for continuation grants. Milestones, parent/child issue links, dependencies,
mentions, and unrelated PRs never extend it.

There is one authority, extended in slices — no parallel record, approval
engine, or admission path is added:

- Shipped (`-010`/`-011`): the action-specific record for `review`,
  `repair`, and `merge` with pinned evidence, expiry, audit events, and the
  write boundaries `Automation::AuthorizeBoundedAction` and
  `Automation::RevokeBoundedAction`, which delegate permission checks to the
  project policy; the model stays validation-only.
- Shipped (`-004`): the shared admission contract
  `Automation::DelegatedActionAdmission` + `Automation::DelegatedWorkBoundary`,
  rechecked at create, queue, dequeue, retry, follow-up, and closeout
  boundaries under the authorization's lock.
- Proposed (#4997–#4999): phase-lifecycle identity, lineage, exclusive stop,
  reassessment, semantic scope assessment, consent surfaces, merge gates, and
  terminal-transition races.

Phase identity comes from `Automation::Phases`; this segment defines no
phases of its own. The shipped action mapping is `review`/`repair` → Coding
with `stop_before_phase` = Merge, and `merge` → Merge with
`stop_before_phase` = Release & Deployment
(`DelegatedActionAdmission::ACTION_PHASES`/`STOP_BEFORE_PHASES`). The
phase-lifecycle slices may make phase and stop selectable only by extending
that mapping; Forager-style project milestones are never a scope.

The authorization stores its author, consent projection, permitted actions,
intent/acceptance references, policy signature, lifecycle timestamps, and
audit references. All records use project/account tenant scoping and normal
actor policy checks. Expiry, completion, revocation, and superseded are
terminal for admission of the delegated action until a new explicit
authorization; a revoked, expired, or terminal record never falls through to
project defaults for that delegated action on that lineage
(`BOUNDED-PHASE-AUTHORIZATION-004`). Recovery from a terminal record is
always an explicit authorized act on that lineage — a new explicit
authorization, or an explicit release that returns the lineage to ordinary
project policy — recorded as the lineage's governing decision, never an
implicit fall-through. Reassessment-required pauses admission until an
authorized actor resolves it by stopping, superseding, or resuming the
unchanged authorization.

## Policy composition

`Automation::EffectivePolicy` remains the sole execution-policy result. The
bounded-authorization input has three outcomes:

| Outcome | Effective policy result |
| --- | --- |
| The action is in the selected phase and the authorization is current | Permit as `:bounded_phase_authorization`, then apply existing controls. |
| The lineage would enter the authorization's stop-before phase | Block as `:bounded_phase_stop`, even if project defaults or a continuation grant would permit it. |
| The authorization is revoked, expired, invalid, unknown, or outside scope | Block or require reassessment; never fall through to project defaults for that delegated action on that lineage. |

The exclusive stop resolves against RDR-077's non-stopping continuation
grants as follows, scoped to the authorization's identified lineage only. An
authorization has two separate effects — it delegates the selected phase's
actions and it suppresses automatic advancement into its stop-before phase —
and each lifecycle state resolves both:

- **Active or reassessment-paused** — the stop holds even when project
  defaults or a continuation grant covering the endpoint would advance the
  lineage into the stop-before phase.
- **Completed at its endpoint** — the stop persists; entering the
  stop-before phase requires a new explicit authorization. Reopening does not
  revive the authorization.
- **Expired** — admission fails closed to a visible reassessment decision;
  the lineage does not silently advance past the stop.
- **Stopped through reassessment** — an authorized actor resolved a
  reassessment by stopping the authorization, so the unchanged authorization is
  no longer resumable; the stop holds and the lineage stays parked until a
  later explicit authorization or an explicit return of the lineage to ordinary
  project policy.
- **Revoked** — the delegation is withdrawn, so the delegated actions it
  covered start no new action (`BOUNDED-PHASE-AUTHORIZATION-004`, the
  shipped fail-closed lifecycle contract). The suppression is not silently
  released: the stop-before phase is not entered automatically, and recovery
  is one explicit authorized decision — a new explicit authorization or an
  explicit return of the lineage to ordinary project policy — recorded as the
  lineage's governing decision. This differs from RDR-077's purely additive
  continuation grants, whose revocation restores project defaults: a grant
  suppresses nothing, so withdrawing one cannot broaden authority.
  Consent and revocation surfaces show this effect.
- **Superseded** — a newer explicit authorization governs the lineage and its
  boundary; the superseded instrument neither authorizes nor constrains
  anything.

Ordinary continuation grants keep their endpoint behavior everywhere else: a
bounded authorization never disables a grant or project setting, and never
affects any other lineage. RDR-080's delegation posture remains a
decision-delegation input to the same effective policy; it neither supplies
nor overrides execution authority.

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
remaining repository checks (review freshness stays owned by the existing
merge policy — an authorization never makes a stale approval current),
invalidators, expiry, and revocation consequences. The write command requires
explicit confirmation and delegates permission checks to the project policy.
Read projections use the same policy decision so the surfaces cannot
disagree.

## Merge, releases, and existing policies

Coding ends at merge-ready. Selecting merge is a separate delegate-able action
and permits an attempt only after existing checks, branch protection,
security, and required fresh reviews for the current head succeed, evaluated
by the existing merge path. Neither selection authorizes release or
deployment. Feature approval, confidence-driven readiness, and RDR-077 phase
settings/grants remain conditions evaluated by the shared policy, not copied
into this record.

## Rollout guard

`automation_phases` (RDR-077) stays default-off and is the required gate for
phase-lifecycle enforcement; every new policy decision reads it through the
existing flag surface. The shipped foundation is inert by construction: no
user-facing surface creates authorizations, admission only rechecks records
that already exist, and no GitHub approval, review, run, or continuation
grant mints one. Exposing the **Authorize bounded phase** action requires a
named, default-off enablement surface added with #4999's consent surfaces;
no migration grants authority, and rollback follows RDR-077's guard rules.

## Test-first implementation slices

Slices are independently verifiable and map to the tracking issues; each
writes its failing-first EARS-linked specs before implementation.

1. **#4997 — identity, lineage, exclusive stop (`-001`–`-003`).** Model,
   command, and lineage specs extend the shipped record with PR-rooted work
   items, same-work lineage, selectable phase/stop mapping, and policy
   signature pinning; effective-policy and queue specs prove the exclusive
   stop despite enabled downstream defaults and grants, plus
   create/dequeue/follow-up decisions.
2. **#4998 — reassessment and semantic scope (`-005`–`-006`).** Invalidation
   and reassessment specs cover stop/supersede/resume transitions and repeated
   triggers; scope-assessment specs prove bounded `agent_harness` input and
   fail-closed malformed, unavailable, unknown, and out-of-scope outcomes.
3. **#4999 — consent surfaces, merge gates, races (`-007`–`-009`).** Request,
   Inbox, chat, API, and MCP specs establish identical consent and status
   projections, actor/tenant isolation, and repository-review blockers;
   merge-policy specs pin coding-stops-at-merge-ready and current-head review
   freshness; transaction/concurrency and reopen specs cover
   completion/revocation/reassessment races with dequeue and follow-up.
4. **#5000 — closeout.** Evidence-based audit of every claim against shipped
   code, tests, and docs, following `docs/rdrs/closeout-checklist.md`.
