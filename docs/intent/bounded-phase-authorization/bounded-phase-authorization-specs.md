---
parent: PAID
prefix: BOUNDED-PHASE-AUTHORIZATION
---

# EARS Specs: Bounded Delivery-Phase Authorization

Status markers: `[ ]` proposed implementation gap.

The initial bounded delegated action contract is shipped as the durable,
action-specific authorization boundary below. The broader phase lifecycle
claims remain proposed until their admission and reassessment paths land.

- [x] **BOUNDED-PHASE-AUTHORIZATION-010** — When an authorized actor delegates a
  bounded delivery action, the system SHALL require an identified issue in the
  same project and account, a pinned sha256 intent digest, and acceptance
  evidence; it SHALL persist the actor, action, expiry, and evidence and record
  an audit event in the same transaction. Revocation SHALL record a
  `bounded_action.revoked` account activity event in the same transaction as
  the status change.
  *Verified by:* `spec/services/automation/authorize_bounded_action_spec.rb` and
  `spec/models/bounded_delegated_action_spec.rb`.

- [x] **BOUNDED-PHASE-AUTHORIZATION-011** — The system SHALL authorize review and
  repair using the existing run permission and SHALL require the stronger
  merge-delegation permission for merge. Product decisions, feature approval,
  release, deployment, and setting enablement SHALL never be delegable
  delivery actions. Revocation SHALL pass the same action-specific permission
  gate as authorization.
  *Verified by:* `spec/models/bounded_delegated_action_spec.rb` and
  `spec/services/automation/authorize_bounded_action_spec.rb` and
  `spec/services/automation/revoke_bounded_action_spec.rb`.

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

- [x] **BOUNDED-PHASE-AUTHORIZATION-004** — Before creating, dequeuing,
  retrying, or scheduling a follow-up action, the system SHALL recheck tenant,
  actor policy, authorization lifecycle, expiry, lineage, stop boundary,
  current policy signature, and deterministic repository controls; a revoked,
  completed, expired, or invalid authorization SHALL start no new action.
  *Verified by:* `spec/services/automation/delegated_work_boundary_spec.rb`.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-005** — When pinned intent/acceptance
  expands, policy or permissions change, a new risk appears, or repair-to-scope
  correspondence is unknown or out of scope, the system SHALL visibly require
  reassessment and SHALL not continue until an authorized actor stops the
  authorization, supersedes it with newly consented scope, or resumes only the
  unchanged authorization; a resume SHALL NOT broaden scope and SHALL be
  re-evaluated when the triggering condition recurs.
  *Planned tests:* invalidation and reassessment specs, including resumption of
  an unchanged authorization after a triggering condition resolves without
  scope expansion (for example a policy change that is restored).

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
