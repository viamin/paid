---
parent: PAID
prefix: BOUNDED-PHASE-AUTHORIZATION
---

# EARS Specs: Bounded Delivery-Phase Authorization

Status markers: `[ ]` proposed implementation gap.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-001** — When an authorized actor explicitly
  confirms a bounded authorization, the system SHALL record the actor, tenant,
  identified issue or PR, established same-work lineage, pinned intent and
  acceptance evidence, selected phase/actions, exclusive stopping boundary,
  policy signature, expiry, and audit event; it SHALL NOT derive this authority
  from a GitHub approval, mention, dependency, parent/child relation, or
  milestone membership.
  *Planned tests:* model and command specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-002** — When a bounded authorization is
  active, the system SHALL permit only its selected phase's in-scope review and
  repair actions on the identified lineage, and SHALL require explicit supported
  authorization for another issue, child, PR, milestone-wide scope, release,
  deployment, or setting enablement.
  *Planned tests:* effective-policy and lineage specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-003** — When the identified lineage would
  enter the selected next phase, the system SHALL stop it with a visible
  `bounded_phase_stop` result even if project defaults or an ordinary
  continuation grant would otherwise permit that phase; ordinary RDR-077 grants
  SHALL retain their current non-stopping behavior.
  *Planned tests:* effective-policy and queue specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-004** — Before creating, dequeuing,
  retrying, or scheduling a follow-up action, the system SHALL recheck tenant,
  actor policy, authorization lifecycle, expiry, lineage, stop boundary,
  current policy signature, and deterministic repository controls; a revoked,
  completed, expired, or invalid authorization SHALL start no new action.
  *Planned tests:* admission, dequeue, retry, and follow-up specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-005** — When pinned intent/acceptance
  expands, policy or permissions change, a new risk appears, or repair-to-scope
  correspondence is unknown or out of scope, the system SHALL visibly require
  reassessment and SHALL not continue until an authorized actor stops or issues
  new explicit consent.
  *Planned tests:* invalidation and reassessment specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-006** — When semantic correspondence is
  evaluated, the system SHALL use `agent_harness` with bounded evidence and a
  structured outcome, SHALL fail closed on unavailable or malformed output, and
  SHALL NOT let that outcome waive deterministic policy.
  *Planned tests:* scope-assessment specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-007** — When coding is selected, the
  system SHALL stop at merge-ready and SHALL NOT merge; when merge is selected,
  it SHALL still require CI, security, branch protection, mergeability, and all
  required fresh reviews for the current head, without treating an older GitHub
  approval as current evidence.
  *Planned tests:* merge-policy and request specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-008** — Inbox, work detail, chat, API, and
  tool operations SHALL use the same authorization policy and SHALL display the
  scope, current state, remaining checks, invalidators, expiry/revocation, and
  next stop before consent and during execution.
  *Planned tests:* request, Inbox, chat, API, and MCP specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-009** — Authorization completion,
  revocation, reassessment, and endpoint admission SHALL be concurrency-safe;
  when either terminal transition races a dequeue or follow-up, at most the
  already-admitted action may proceed and no next-phase action SHALL start.
  Reopening completed work SHALL NOT reactivate the authorization.
  *Planned tests:* transaction/concurrency and reopen specs.
