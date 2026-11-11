---
parent: PAID
prefix: BOUNDED-PHASE-AUTHORIZATION
---

# EARS Specs: Bounded Delivery-Phase Authorization

Status markers: `[ ]` proposed implementation gap.

The design is accepted (RDR-078, 2026-11-11, #4996). The shipped foundation
is the durable `BoundedDelegatedAction` record (`-010`, `-011`) and the
shared deterministic admission rechecks (`-004`); those remain the single
authority. The phase-lifecycle claims below extend those contracts — they
must not add a second authorization record, approval engine, or admission
path — and map to implementation slices #4997 (`-001`–`-003`), #4998
(`-005`–`-006`), and #4999 (`-007`–`-009`).

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

- [ ] **BOUNDED-PHASE-AUTHORIZATION-001** — When an authorized actor explicitly
  confirms a bounded authorization, the system SHALL extend the shipped
  `BoundedDelegatedAction` record so it also persists the identified issue or
  PR root work item, its established same-work lineage as resolved by
  `Automation::ContinuationGrantLookup`, the selected phase/actions and
  exclusive stopping boundary beyond the fixed action mapping, the actor,
  tenant, pinned intent and acceptance evidence, policy signature, expiry, and
  audit event; it SHALL NOT derive this authority from a GitHub approval,
  mention, dependency, parent/child relation, or milestone membership, and
  SHALL NOT add a second authorization record.
  *Planned tests (#4997):* model, command, and lineage specs extending
  `spec/models/bounded_delegated_action_spec.rb` and
  `spec/services/automation/authorize_bounded_action_spec.rb`.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-002** — When a bounded authorization is
  active, the system SHALL permit only its selected phase's in-scope review and
  repair actions on the identified lineage, composed through
  `Automation::EffectivePolicy` and the existing continuation lookup, and
  SHALL require explicit supported authorization for another issue, child,
  PR, milestone-wide scope, release, deployment, or setting enablement.
  *Planned tests (#4997):* effective-policy and lineage specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-003** — When the identified lineage would
  enter the authorization's stop-before phase, the system SHALL stop it with a
  visible `bounded_phase_stop` result even if project defaults or an ordinary
  continuation grant would otherwise permit that phase; the stop SHALL persist
  after the authorization completes at its endpoint (reopening SHALL NOT
  reactivate it), SHALL fail closed to a visible reassessment decision on
  expiry, and SHALL be retained when the authorization is revoked or stopped
  through reassessment — withdrawal never silently releases the suppressed
  automation — until an authorized actor explicitly returns the lineage to
  ordinary project policy or a newer explicit authorization supersedes it.
  Ordinary RDR-077 grants, project phase settings, and manual-start endpoints
  SHALL retain their current non-stopping behavior and SHALL NOT gain a stop
  option.
  *Shipped foundation:* `Automation::DelegatedWorkBoundary` already blocks a
  delegated action whose current phase equals the authorization's
  stop-before phase (`bounded_stop`), and a revoked, completed, or expired
  authorization already starts no new action (`-004`); this claim adds the
  composition against continuation grants and project defaults, the visible
  `bounded_phase_stop` result, and the terminal lifecycle above.
  *Planned tests (#4997):* effective-policy, queue, and lifecycle specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-005** — When pinned intent/acceptance
  expands, policy or permissions change, a new risk appears, or repair-to-scope
  correspondence is unknown or out of scope, the system SHALL visibly require
  reassessment and SHALL not continue until an authorized actor stops the
  authorization, supersedes it with newly consented scope, or resumes only the
  unchanged authorization; a resume SHALL NOT broaden scope and SHALL be
  re-evaluated when the triggering condition recurs. Stopping the
  authorization SHALL retain the lineage's stop until a later explicit
  authorization or an explicit return of the lineage to ordinary project
  policy.
  *Planned tests (#4998):* invalidation and reassessment specs, including
  resumption of an unchanged authorization after a triggering condition
  resolves without scope expansion (for example a policy change that is
  restored).

- [ ] **BOUNDED-PHASE-AUTHORIZATION-006** — When semantic correspondence is
  evaluated, the system SHALL use `agent_harness` with bounded evidence and a
  structured outcome, SHALL fail closed on unavailable or malformed output, and
  SHALL NOT let that outcome waive deterministic policy.
  *Planned tests (#4998):* scope-assessment specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-007** — When coding is selected, the
  system SHALL stop at merge-ready and SHALL NOT merge; when merge is selected,
  it SHALL still require CI, security, branch protection, mergeability, and all
  required fresh reviews for the current head, without treating an older GitHub
  approval as current evidence.
  *Planned tests (#4999):* merge-policy and request specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-008** — Inbox, work detail, chat, API, and
  tool operations SHALL use the same authorization policy and SHALL display the
  scope, current state, remaining checks, invalidators, expiry/revocation, and
  next stop before consent and during execution.
  *Planned tests (#4999):* request, Inbox, chat, API, and MCP specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-009** — Authorization completion,
  revocation, reassessment, and endpoint admission SHALL be concurrency-safe;
  when either terminal transition races a dequeue or follow-up, at most the
  already-admitted action may proceed and no next-phase action SHALL start.
  Reopening completed work SHALL NOT reactivate the authorization.
  *Planned tests (#4999):* transaction/concurrency and reopen specs.
