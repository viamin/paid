---
parent: PAID
prefix: PROJECT-DELEGATION
---

# EARS Specs: Project Delegation After Settled Intent

Status markers: `[ ]` planned implementation gap.

- [x] **PROJECT-DELEGATION-001** — When an authorized owner or project admin
  selects a project delegation posture, the system SHALL default every project
  to `conservative`, SHALL show the effective posture and remaining required
  human reviews, and SHALL record the actor, project, revision, enabled action
  classes, and audit event. The audit event SHALL reject independent update or
  deletion while allowing removal only through teardown of its owning account.
  *Verified by:* `spec/services/project_delegation/posture_spec.rb`
  (conservative default, guarded effective posture, enabled action classes,
  remaining-review display data),
  `spec/services/project_delegation/select_posture_spec.rb` (authorized
  selection, revision increment, immutable audit event, guard failures),
  `spec/models/project_delegation_posture_spec.rb` (durable record shape),
  `spec/models/account_spec.rb` (owning-account teardown),
  `spec/requests/projects/delegation_postures_spec.rb` (settings surface
  selection and display), and the posture additions to
  `spec/services/project_delegation/projection_spec.rb`,
  `spec/requests/api/v1/delegation_spec.rb`, and
  `spec/mcp/tools/get_project_delegation_spec.rb` (shared projection parity).

- [ ] **PROJECT-DELEGATION-002** — When material product questions are known
  before downstream work, the system SHALL group related questions, show a
  recommendation and consequences, and bind a human's settled answers to the
  immutable design and acceptance revision; it SHALL NOT ask again downstream
  unless new evidence conflicts with, invalidates, or materially expands it.

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

- [x] **PROJECT-DELEGATION-005** — UI, API, MCP, queue, dequeue, retries, and
  background jobs SHALL use `Automation::EffectivePolicy` and the same
  delegation projection; no surface SHALL infer authority from a label, stale
  approval, queue state, or local UI state.
  *Verified by:*
  `spec/services/project_delegation/projection_spec.rb` (the one shared read
  model: `Automation::EffectivePolicy` decisions, bounded authorization
  lifecycle, admission-contract posture signature),
  `spec/requests/projects/automation_phases_spec.rb` (settings surface),
  `spec/requests/projects/agent_runs_continuation_spec.rb` and
  `spec/services/inbox/chat_context_spec.rb` (Inbox/work-detail surfaces),
  `spec/requests/api/v1/delegation_spec.rb` (API surface, same signature as
  the settings projection), and `spec/mcp/tools/get_project_delegation_spec.rb`
  (MCP surface), `spec/services/automation/delegated_action_admission_spec.rb`
  (shared effective-policy evaluation, including a disabled coding phase for
  repair), `spec/temporal/activities/queue_agent_run_activity_spec.rb` (queue
  and follow-up), `spec/jobs/process_run_queue_job_spec.rb` (dequeue, including
  retry-minted runs), and
  `spec/temporal/activities/merge_pull_request_activity_spec.rb` (closeout).
  Repair work enters through the same queue admission mapping as
  `layered_verification_repair`.

- [x] **PROJECT-DELEGATION-006** — When a project setting broadens delegated
  authority, the system SHALL apply the broader posture only to new admissions
  and SHALL NOT silently broaden an in-flight authorization; when a project
  setting narrows delegated authority, the settings surface SHALL require a
  rollback reason and record a `project_delegation.rollback` audit event; when
  expiry, revocation, or a bounded stop occurs, the system SHALL prevent the
  next action while preserving
  audit/evidence history and exposing a recovery decision.
  *Verified by:* `spec/requests/projects/delegation_postures_spec.rb` (auditable
  reasoned settings rollback), `spec/services/automation/delegated_work_boundary_spec.rb`,
  `spec/services/automation/delegated_action_admission_spec.rb` (posture
  change and revocation rechecks), and
  `spec/services/automation/focused_decision_spec.rb` (one recovery decision
  whose metadata tracks the current failure).

- [x] **PROJECT-DELEGATION-007** — For each opted-in project, the system SHALL
  record revision-aware human Inbox decisions per completed issue, decision
  time, completion rate, and later-reversed decisions; it SHALL keep broadening
  disabled until the RDR-080 pilot threshold is met and SHALL pause expansion
  on a material reversal, security/tenant/trust breach, missing security
  assessment, or missing evidence.
  *Verified by:* `spec/services/project_delegation/pilot_metrics_spec.rb`,
  `spec/services/project_delegation/expansion_guard_spec.rb`,
  `spec/services/project_delegation/posture_spec.rb`,
  `spec/temporal/activities/mark_agent_run_complete_activity_spec.rb`,
  `spec/services/feature_intents/respond_to_decision_spec.rb`, and
  `spec/services/automation/delegated_work_boundary_spec.rb` (production
  lifecycle recording, revision-cohort isolation, pilot thresholds,
  default-off expansion, enforced rollback, and pause signals).

- [ ] **PROJECT-DELEGATION-008** — When a delegated action records a focused
  follow-up, the system SHALL record the finding, affected scope, evidence,
  owner, and completion dependency exactly once, SHALL keep evidence-gated
  closeout blocked while a material follow-up is open, and SHALL NOT execute
  that follow-up under the delegated authority; the follow-up's own execution
  SHALL require its own admission, policy snapshot, and boundary rechecks.

- [x] **PROJECT-DELEGATION-009** — When a completed report-only acceptance
  audit captured an effective `bounded_delivery` posture with delegated issue
  closure and an enabled Merge phase, the system SHALL attempt one evidence-
  gated GitHub closure only if that same authority and a current fully accepted
  assessment still hold. A conservative or newly broadened project, stale or
  partial assessment, satisfied criterion without cited evidence, active hold or prerequisite, upstream-managed issue,
  scanner record, or failed GitHub write SHALL leave the source issue visible
  for human recovery. Successful closure SHALL record the system initiator,
  audit run, policy revision, evidence digest, and evidence-linked rationale.
  *Code:* `app/services/issues/auto_resolve_closeout.rb`,
  `app/jobs/auto_resolve_closeout_job.rb`,
  `app/temporal/activities/run_acceptance_audit_activity.rb`.
  *Tests:* `spec/services/issues/auto_resolve_closeout_spec.rb`,
  `spec/temporal/activities/run_acceptance_audit_activity_spec.rb`.
