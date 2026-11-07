---
parent: PAID
prefix: PROJECT-DELEGATION
---

# EARS Specs: Project Delegation After Settled Intent

Status markers: `[ ]` planned implementation gap.

- [ ] **PROJECT-DELEGATION-001** — When an authorized owner or project admin
  selects a project delegation posture, the system SHALL default every project
  to `conservative`, SHALL show the effective posture and remaining required
  human reviews, and SHALL record the actor, project, revision, enabled action
  classes, and audit event.

- [x] **PROJECT-DELEGATION-002** — When material product questions are known
  before downstream work, the system SHALL group related questions, show a
  recommendation and consequences, and bind a human's settled answers to the
  immutable design and acceptance revision; it SHALL NOT ask again downstream
  unless new evidence conflicts with, invalidates, or materially expands it.
  *Tests:* `spec/services/project_delegation/intent_checkpoint/plan_spec.rb`
  (grouping, presentation, revision tokens),
  `spec/services/project_delegation/intent_checkpoint/open_spec.rb`
  (one pending checkpoint per work item, supersede on revision change, one
  Inbox request), `spec/services/project_delegation/intent_checkpoint/settle_spec.rb`
  (settle/reject/amend, authority, audit, immutable binding),
  `spec/services/project_delegation/intent_checkpoint/gate_spec.rb`
  (no re-ask while current; one focused re-decision on revision delta),
  `spec/models/delegation_intent_checkpoint_spec.rb`,
  `spec/models/delegation_intent_settlement_spec.rb` (append-only rows),
  `spec/requests/projects/intent_checkpoints_spec.rb` (authorized human
  settlement over HTTP), and the checkpoint-boundary examples of
  `spec/services/automation/delegated_action_admission_spec.rb`.
  *Code:* `app/services/project_delegation/intent_checkpoint/plan.rb`,
  `app/services/project_delegation/intent_checkpoint/revisions.rb`,
  `app/services/project_delegation/intent_checkpoint/open.rb`,
  `app/services/project_delegation/intent_checkpoint/settle.rb`,
  `app/services/project_delegation/intent_checkpoint/gate.rb`,
  `app/models/delegation_intent_checkpoint.rb`,
  `app/models/delegation_intent_settlement.rb`,
  `app/controllers/projects/intent_checkpoints_controller.rb`,
  `app/policies/project_policy.rb` (`settle_intent_checkpoint?`),
  `app/services/automation/delegated_action_admission.rb` (Gate consult),
  migration `db/migrate/20261107090000_create_delegation_intent_checkpoints.rb`.

- [ ] **PROJECT-DELEGATION-003** — When `bounded_delivery` is current, the
  system SHALL delegate only bounded implementation choices, focused follow-up
  ownership, technical-stop recovery, evidence-gated issue closure, and
  bounded cycle analysis/repair, each with the action-specific evidence and
  audit record defined by RDR-080; it SHALL NOT delegate product behavior,
  requirements, scope, acceptance criteria, explicit holds, release,
  deployment, settings changes, or new work lineage, except for the narrow
  follow-up recording exception in PROJECT-DELEGATION-008.

- [x] **PROJECT-DELEGATION-004** — Before creating, queueing, dequeueing,
  retrying, following up, repairing, or closing delegated work, the system
  SHALL recheck current intent, acceptance, and evidence revisions; posture
  signature; applicable RDR-077/RDR-078 policy; tenant, trust, budget, and
  repository controls; any mismatch or unavailable assessment SHALL route to
  a focused human decision.
  *Verified by:* `spec/services/automation/authorize_bounded_action_spec.rb`
  (canonical admission evidence),
  `spec/services/automation/delegated_work_boundary_spec.rb`,
  `spec/services/automation/delegated_action_admission_spec.rb`, the
  delegated-work contexts of `spec/temporal/activities/queue_agent_run_activity_spec.rb`
  (create/queue and follow-up-tagged boundaries),
  `spec/temporal/activities/merge_pull_request_activity_spec.rb` (closeout
  boundary), `spec/jobs/process_run_queue_job_spec.rb` (dequeue boundary, which
  every queued retry must pass), and
  `spec/services/automation/focused_decision_spec.rb` (dedup and refresh).

- [ ] **PROJECT-DELEGATION-005** — UI, API, MCP, queue, dequeue, retries, and
  background jobs SHALL use `Automation::EffectivePolicy` and the same
  delegation projection; no surface SHALL infer authority from a label, stale
  approval, queue state, or local UI state.

- [x] **PROJECT-DELEGATION-006** — When a project setting broadens delegated
  authority, the system SHALL apply the broader posture only to new admissions
  and SHALL NOT silently broaden an in-flight authorization; when a project
  setting narrows delegated authority, or when expiry, revocation, or a bounded
  stop occurs, the system SHALL prevent the next action while preserving
  audit/evidence history and exposing a recovery decision.
  *Verified by:* `spec/services/automation/delegated_work_boundary_spec.rb`,
  `spec/services/automation/delegated_action_admission_spec.rb` (posture
  change and revocation rechecks), and
  `spec/services/automation/focused_decision_spec.rb` (one recovery decision
  whose metadata tracks the current failure).

- [ ] **PROJECT-DELEGATION-007** — For each opted-in project, the system SHALL
  record revision-aware human Inbox decisions per completed issue, decision
  time, completion rate, and later-reversed decisions; it SHALL keep broadening
  disabled until the RDR-080 pilot threshold is met and SHALL pause expansion
  on a material reversal, security/tenant/trust breach, or missing evidence.

- [ ] **PROJECT-DELEGATION-008** — When a delegated action records a focused
  follow-up, the system SHALL record the finding, affected scope, evidence,
  owner, and completion dependency exactly once, SHALL keep evidence-gated
  closeout blocked while a material follow-up is open, and SHALL NOT execute
  that follow-up under the delegated authority; the follow-up's own execution
  SHALL require its own admission, policy snapshot, and boundary rechecks.
