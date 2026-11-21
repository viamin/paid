---
parent: PAID
prefix: BOUNDED-PHASE-AUTHORIZATION
---

# EARS Specs: Bounded Delivery-Phase Authorization

Status markers: `[ ]` accepted implementation gap.

The initial bounded delegated action contract is shipped as the durable,
action-specific authorization boundary below. The phase identity, lineage,
and exclusive-stop claims (`-001`–`-003`) shipped with #4997; the reassessment,
consent-surface, and concurrency claims remain unchecked until their
admission paths land.

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

- [x] **BOUNDED-PHASE-AUTHORIZATION-001** — When an authorized actor explicitly
  confirms a bounded authorization, the system SHALL record the actor, tenant,
  identified issue or PR, established same-work lineage, pinned intent and
  acceptance evidence, selected phase/actions, exclusive stopping boundary,
  policy signature, expiry, and audit event; it SHALL NOT derive this authority
  from a GitHub approval, mention, dependency, parent/child relation, or
  milestone membership. It SHALL extend the shipped `-010` evidence/audit
  record and SHALL NOT create another delegated-action authority.
  *Verified by:* `spec/services/automation/authorize_bounded_action_spec.rb`
  (explicit lineage pinning for issue and PR work items, lineage-bearing audit
  event, and no authority minted from relations, mentions, dependencies, or
  milestone membership) and `spec/models/bounded_delegated_action_spec.rb`
  (pinned-lineage validation, coverage, phase/stop identity, and the
  auditable `completed_at` lifecycle).

- [x] **BOUNDED-PHASE-AUTHORIZATION-002** — When a bounded authorization is
  active, the system SHALL permit only its selected phase's in-scope review and
  repair actions on the identified lineage, and SHALL require explicit supported
  authorization for another issue, child, PR, milestone-wide scope, release,
  deployment, or setting enablement. It SHALL compose the shipped `-011`
  action permissions and `-004` admission boundary rather than duplicate them.
  *Verified by:* `spec/services/automation/delegated_action_admission_spec.rb`
  (same-work lineage admission for the linked PR through the root issue's
  authorization, non-inheritance for another issue, decomposed child,
  unrelated PR, and a PR linked after admission; tenant isolation; and
  create/dequeue/follow-up boundary rechecks of lineage-governed work) and the
  lineage isolation examples of `spec/services/automation/effective_policy_spec.rb`.

- [x] **BOUNDED-PHASE-AUTHORIZATION-003** — When the identified lineage would
  enter the selected next phase, the system SHALL stop it with a visible
  `bounded_phase_stop` result even if project defaults or an ordinary
  continuation grant would otherwise permit that phase; ordinary RDR-077 grants
  SHALL retain their current non-stopping behavior. This extends the shipped
  `-004` fail-closed boundary result with a `bounded_phase_stop`; it SHALL NOT
  change continuation-grant endpoint semantics. Where no bounded authorization
  governs the lineage, the system SHALL preserve the project's existing phase
  and auto-merge policy, including fully automatic merging of qualifying PRs
  without a new per-PR human decision.
  *Verified by:* `spec/services/automation/effective_policy_spec.rb`
  (exclusive stop over enabled defaults and covering grants, lineage-scoped
  stop, stop survival across revocation/expiry/completion, supersession by an
  active phase selection, unchanged grants and defaults, manual-action and
  rollout-guard exclusions) and the bounded-stop examples of
  `spec/services/automation/feature_activation_phase_gate_spec.rb` (the
  auto-merge queue entry point keeps a stopped lineage off while a superseding
  merge authorization restores it).

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

- [x] **BOUNDED-PHASE-AUTHORIZATION-005** — When pinned intent/acceptance
  expands, policy or permissions change, a new risk appears, or repair-to-scope
  correspondence is unknown or out of scope, the system SHALL visibly require
  reassessment and SHALL not continue until an authorized actor stops the
  authorization, supersedes it with newly consented scope, or resumes only the
  unchanged authorization; a resume SHALL NOT broaden scope and SHALL be
  re-evaluated when the triggering condition recurs.
  *Verified by:* `spec/services/automation/delegated_action_admission_spec.rb`
  (semantic-triggered visible pause and persisted reasons) and
  `spec/services/automation/resolve_bounded_reassessment_spec.rb` (authorized
  stop, revalidation-required unchanged-scope resume, immutable pinned scope,
  and audit evidence).

- [x] **BOUNDED-PHASE-AUTHORIZATION-006** — When semantic correspondence is
  evaluated, the system SHALL use `agent_harness` with bounded evidence and a
  structured outcome, SHALL fail closed on unavailable or malformed output, and
  SHALL NOT let that outcome waive deterministic policy.
  *Verified by:* `spec/services/automation/assess_bounded_scope_spec.rb`
  (bounded structured `agent_harness` request and unavailable/malformed
  fail-closed outcomes) and
  `spec/services/automation/delegated_action_admission_spec.rb` (unknown
  correspondence pauses admission rather than waiving deterministic checks).

- [ ] **BOUNDED-PHASE-AUTHORIZATION-007** — When coding is selected, the
  system SHALL stop at merge-ready and SHALL NOT merge; when merge is selected,
  it SHALL still require CI, security, branch protection, mergeability, and all
  required fresh reviews for the current head, without treating an older GitHub
  approval as current evidence. Review freshness remains owned by the
  auto-merge strategy; this authorization never refreshes a review.
  *Planned delivery:* #4999. *Planned tests:* merge-policy and request specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-008** — Inbox, work detail, chat, API, and
  tool operations SHALL use the same authorization policy and SHALL display the
  scope, current state, remaining checks, invalidators, expiry/revocation, and
  next stop before consent and during execution. The consent surface SHALL
  default to inheriting project policy and SHALL create no bounded stop until
  an authorized user explicitly confirms one; it SHALL show how a selected
  stop overrides fully automatic merge and how an independent human-only hold
  remains effective.
  *Planned delivery:* #4999. *Planned tests:* request, Inbox, chat, API, and MCP specs.

- [ ] **BOUNDED-PHASE-AUTHORIZATION-009** — Authorization completion,
  revocation, reassessment, and endpoint admission SHALL be concurrency-safe;
  when either terminal transition races a dequeue or follow-up, at most the
  already-admitted action may proceed and no next-phase action SHALL start.
  Reopening completed work SHALL NOT reactivate the authorization.
  *Planned delivery:* #4999. *Planned tests:* transaction/concurrency and reopen specs.
