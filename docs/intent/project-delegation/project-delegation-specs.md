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
  classes, and audit event.
  *Verified by:* `spec/models/project_delegation_posture_spec.rb` (one
  tenant-isolated row per project, default `conservative`, monotonic revision,
  immutable audit events on every lifecycle write) and
  `spec/services/project_delegation/posture_spec.rb` (guarded selection,
  effective-posture resolution with default/selected/guard-disabled states,
  and the remaining required human reviews each state exposes).

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
  `spec/services/automation/delegated_action_admission_spec.rb` (revision,
  posture, and assessment rechecks),
  the delegated-work contexts of `spec/temporal/activities/queue_agent_run_activity_spec.rb`
  (create/queue and follow-up-tagged boundaries),
  `spec/temporal/activities/merge_pull_request_activity_spec.rb` (closeout
  boundary), `spec/jobs/process_run_queue_job_spec.rb` (dequeue boundary, which
  every queued retry must pass), and
  `spec/services/automation/focused_decision_spec.rb` (dedup and refresh).

- [ ] **PROJECT-DELEGATION-005** — UI, API, MCP, queue, dequeue, retries, and
  background jobs SHALL use `Automation::EffectivePolicy` and the same
  delegation projection; no surface SHALL infer authority from a label, stale
  approval, queue state, or local UI state.
  PR #4918 delivers only the shared read projection for UI, API, and MCP;
  it does not complete this requirement or close #4879.
  *Read-surface verification:*
  `spec/services/project_delegation/projection_spec.rb` (the one shared read
  model: `Automation::EffectivePolicy` decisions, bounded authorization
  lifecycle, admission-contract posture signature),
  `spec/requests/projects/automation_phases_spec.rb` (settings surface),
  `spec/requests/projects/agent_runs_continuation_spec.rb` and
  `spec/services/inbox/chat_context_spec.rb` (Inbox/work-detail surfaces),
  `spec/requests/api/v1/delegation_spec.rb` (API surface, same signature as
  the settings projection), and `spec/mcp/tools/get_project_delegation_spec.rb`
  (MCP surface). Completing #4879 still requires the shared `ActionPlan`
  write/admission contract for queue, dequeue, retry, follow-up, closeout, and
  repair boundaries.

- [x] **PROJECT-DELEGATION-006** — When a project setting broadens delegated
  authority, the system SHALL apply the broader posture only to new admissions
  and SHALL NOT silently broaden an in-flight authorization; when a project
  setting narrows delegated authority, or when expiry, revocation, an explicit
  hold, or a bounded stop occurs, the system SHALL prevent the next action
  while preserving audit/evidence history and exposing a recovery decision.
  *Verified by:* `spec/services/automation/delegated_work_boundary_spec.rb`,
  `spec/services/automation/delegated_action_admission_spec.rb` (posture
  broadening, hold, expiry, and revocation rechecks),
  `spec/services/project_delegation/posture_spec.rb` (hold and release with
  audit retention), `spec/services/project_delegation/rollback_spec.rb`
  (conservative rollback that blocks the next delegated boundary, preserves
  authorizations/evidence and audit history, and routes one focused recovery
  decision per in-flight delegated authorization), and
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
