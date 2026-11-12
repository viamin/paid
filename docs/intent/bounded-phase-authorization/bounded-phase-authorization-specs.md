---
parent: PAID
prefix: BOUNDED-PHASE-AUTHORIZATION
---

# EARS Specs: Bounded Delivery-Phase Authorization

Status markers: `[ ]` proposed implementation gap.

The initial bounded delegated action contract is shipped as the durable,
action-specific authorization boundary below. The broader phase lifecycle
claims remain proposed until their admission and reassessment paths land.

`BOUNDED-PHASE-AUTHORIZATION-010`, `-011`, and `-004` are the shipped
authority for authorization writes, permission gates, and admission rechecks.
The remaining claims extend that foundation; they do not restate it and they
add no second authorization or admission engine.

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
  milestone membership, and it SHALL NOT extend the authorization to another
  issue, child work, additional PR, or a phase the actor did not select.
  *Slice:* P01 — phase identity, lineage, and durable authorization (#4997).
  *Planned tests:* model and command specs covering the recorded identity, the
  pinned intent and acceptance evidence, the selected phase and stop-before
  phase, and the absence of any derivation from review, mention, dependency,
  parent/child, or milestone state.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-002** — When a bounded authorization is
  active, the system SHALL permit only its selected phase's in-scope review and
  repair actions on the identified lineage, and SHALL require explicit supported
  authorization for another issue, child, PR, milestone-wide scope, release,
  deployment, or setting enablement.
  *Slice:* P01 — in-scope action enforcement (#4997).
  *Planned tests:* effective-policy and lineage specs asserting that an action
  outside the selected phase or outside the identified lineage is not admitted
  by the authorization, and that release, deployment, and setting enablement
  remain separately authorized.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-003** — When the identified lineage would
  enter the selected next phase, the system SHALL stop it with a visible
  `bounded_phase_stop` result even if project defaults or an ordinary
  continuation grant would otherwise permit that phase; ordinary RDR-077 grants
  SHALL retain their current non-stopping behavior, and a revoked, expired, or
  completed bounded authorization SHALL withdraw both its delegation and its
  suppression for that lineage until an authorized actor records a new explicit
  authorization or an explicit return of the lineage to ordinary project policy.
  *Slice:* P01 — exclusive stop composed with the effective policy (#4997).
  *Planned tests:* effective-policy and queue specs covering the visible stop
  under enabled downstream defaults, the unchanged non-stopping behavior of
  ordinary continuation grants, and the terminal states' withdrawal of both
  effects without a silent fall-through.

- [x] **BOUNDED-PHASE-AUTHORIZATION-004** — Before creating, dequeuing,
  retrying, or scheduling a follow-up action, the system SHALL recheck tenant,
  authorization lifecycle, expiry, stop boundary, current phase policy and
  policy signature, and deterministic repository controls; a revoked,
  completed, expired, or invalid authorization SHALL start no new action.
  *Verified by:* `spec/services/automation/authorize_bounded_action_spec.rb`
  (canonical admission evidence),
  `spec/services/automation/delegated_work_boundary_spec.rb`,
  `spec/services/automation/delegated_action_admission_spec.rb`, the
  delegated-work contexts of
  `spec/temporal/activities/queue_agent_run_activity_spec.rb` and
  `spec/jobs/process_run_queue_job_spec.rb` (queue, follow-up-tagged queue,
  and dequeue boundaries — retry-minted runs pass through the same dequeue
  recheck), and `spec/services/automation/focused_decision_spec.rb`.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-005** — When pinned intent/acceptance
  expands, policy or permissions change, a new risk appears, or repair-to-scope
  correspondence is unknown or out of scope, the system SHALL visibly require
  reassessment and SHALL not continue until an authorized actor stops the
  authorization, supersedes it with newly consented scope, or resumes only the
  unchanged authorization; a resume SHALL NOT broaden scope and SHALL be
  re-evaluated when the triggering condition recurs.
  *Slice:* P02 — reassessment triggers, resolution, and resumption (#4998).
  *Planned tests:* invalidation and reassessment specs, including resumption of
  an unchanged authorization after a triggering condition resolves without
  scope expansion (for example a policy change that is restored), and the
  re-evaluation of a resumed authorization when the trigger recurs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-006** — When semantic correspondence is
  evaluated, the system SHALL use `agent_harness` with bounded evidence and a
  structured outcome, SHALL fail closed on unavailable or malformed output, and
  SHALL NOT let that outcome waive deterministic policy.
  *Slice:* P02 — bounded semantic scope assessment (#4998).
  *Planned tests:* scope-assessment specs covering in-scope, out-of-scope,
  ambiguous, unavailable, and malformed outcomes, and the deterministic controls
  that still apply after each outcome.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-007** — When coding is selected, the
  system SHALL stop at merge-ready and SHALL NOT merge; when merge is selected,
  it SHALL still require CI, security, branch protection, mergeability, and all
  required fresh reviews for the current head, without treating an older GitHub
  approval as current evidence.
  *Slice:* P03 — merge and merge-ready gating (#4999).
  *Planned tests:* merge-policy and request specs asserting that a coding
  selection never merges and that a merge selection never proceeds on an older
  approval, under the current-head review classifier that owns freshness.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-008** — Inbox, work detail, chat, API, and
  tool operations SHALL use the same authorization policy and SHALL display the
  scope, current state, remaining checks, invalidators, expiry/revocation, and
  next stop before consent and during execution.
  *Slice:* P03 — one consent projection across surfaces (#4999).
  *Planned tests:* request, Inbox, chat, API, and MCP specs asserting the same
  scope, state, remaining checks, invalidators, expiry, revocation effect, and
  next stop on every surface, including actor and tenant isolation.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-009** — Authorization completion,
  revocation, reassessment, and endpoint admission SHALL be concurrency-safe;
  when either terminal transition races a dequeue or follow-up, at most the
  already-admitted action may proceed and no next-phase action SHALL start.
  Reopening completed work SHALL NOT reactivate the authorization.
  *Slice:* P03 — terminal transitions and admission races (#4999).
  *Planned tests:* transaction/concurrency and reopen specs covering the
  terminal transitions against a concurrent dequeue or follow-up, and the
  unchanged terminal state after a reopen.
