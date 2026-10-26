# EARS Specs: Automation Phases and Work-Item Authorization

- [x] **AUTOMATION-PHASES-001** — The system SHALL classify every automation
  action into exactly one of the six responsibility phases (Discovery, Issue
  preparation, Coding, Merge, Release & Deployment, Operations), SHALL treat
  Operations as outside the delivery chain, and SHALL offer manual
  continuation endpoints only through merge.
  *Tests:* `spec/services/automation/phases_spec.rb`
  *Code:* `Automation::Phases`

- [x] **AUTOMATION-PHASES-002** — When a project's phase is disabled, the system
  SHALL grant no standing authorization for automatic work in that phase,
  SHALL refuse to let trusted activation labels enable it, and SHALL retain
  every subordinate capability value configured for it.
  *Tests:* `spec/services/automation/phase_settings_spec.rb`,
  `spec/services/automation/feature_activation_phase_gate_spec.rb`
  *Code:* `Automation::PhaseSettings`, `Automation::FeatureActivation`

- [x] **AUTOMATION-PHASES-003** — Every entry point SHALL evaluate one
  effective execution policy that resolves the action's phase and work scope,
  establishes authorization from project defaults, the explicit manual action,
  or an applicable continuation grant, and records why the action is permitted
  or blocked.
  *Tests:* `spec/services/automation/effective_policy_spec.rb`
  *Code:* `Automation::EffectivePolicy`

- [x] **AUTOMATION-PHASES-004** — Authorized users SHALL be able to start a
  manual run in a phase whose project default is disabled, and the resulting
  run SHALL carry the same phase classification as an automatic run performing
  the same action.
  *Tests:* `spec/requests/projects/agent_runs_continuation_spec.rb`
  *Code:* `Projects::AgentRunsController`, `Automation::ManualStart::Plan`

- [x] **AUTOMATION-PHASES-005** — When a manual start requests automatic
  continuation, the system SHALL create one durable continuation grant for
  that work item covering the selected action's phase and only the subsequent
  delivery phases up to the chosen endpoint, and SHALL not cover discovery,
  release, deployment, or operations.
  *Tests:* `spec/models/work_item_continuation_grant_spec.rb`,
  `spec/requests/projects/agent_runs_continuation_spec.rb`
  *Code:* `Automation::ManualStart::Plan`, `WorkItemContinuationGrant`

- [x] **AUTOMATION-PHASES-006** — A continuation grant SHALL survive the
  transition from issue to implementation run, pull request, review, and repair
  runs for the same linked work chain, and SHALL NOT authorize a mere issue
  mention, a shared project, a dependency, or any additional or child issue
  created for the same work.
  *Tests:* `spec/services/automation/continuation_grant_lookup_spec.rb`
  *Code:* `Automation::ContinuationGrantLookup`

- [x] **AUTOMATION-PHASES-007** — While a grant covers an action, the system
  SHALL authorize that action even when the project phase or the automatic
  start/continuation switches are off, while still applying required review
  methods, CI requirements, merge rules, budgets, trust rules, tenant
  permissions, and scheduler safety holds.
  *Tests:* `spec/services/automation/effective_policy_spec.rb`,
  `spec/services/agent_runs/recheck_issue_eligibility_spec.rb`
  *Code:* `Automation::EffectivePolicy`

- [x] **AUTOMATION-PHASES-008** — Reaching a grant's endpoint SHALL complete
  the grant, reopening the work SHALL NOT silently reactivate it, and
  revoking a grant SHALL withdraw only that exception while project defaults
  continue to permit work independently.
  *Tests:* `spec/models/work_item_continuation_grant_spec.rb`,
  `spec/temporal/activities/mark_pr_ready_activity_spec.rb`
  *Code:* `WorkItemContinuationGrant`, `Automation::CompleteContinuationGrants`,
  `Issue`

- [x] **AUTOMATION-PHASES-009** — The system SHALL require permission to
  delegate the actions a grant covers, so automating through merge requires
  permission to delegate merge, and SHALL reject unauthorized grant requests.
  *Tests:* `spec/requests/projects/agent_runs_continuation_spec.rb`
  *Code:* `Automation::ManualStart::Plan`, `ProjectPolicy`

- [x] **AUTOMATION-PHASES-010** — Every manual-start surface SHALL explain
  before submission when the selected endpoint is not the effective automation
  stopping point under current settings, naming the later phases project
  policy permits and the settings responsible, describing continuation as
  conditional authorization rather than a guarantee, and updating as the
  selected action, endpoint, or project changes; the same explanation SHALL be
  available on work details and to API clients creating manual work.
  *Tests:* `spec/services/automation/effective_policy_notice_spec.rb`,
  `spec/requests/projects/agent_runs_continuation_spec.rb`
  *Code:* `Automation::EffectivePolicyNotice`, `Automation::ManualStart::Plan`

- [x] **AUTOMATION-PHASES-011** — The system SHALL re-evaluate the effective
  policy at submission so that a form rendered before a newly permitted
  continuation SHALL return an updated notice for review instead of silently
  omitting that continuation.
  *Tests:* `spec/requests/projects/agent_runs_continuation_spec.rb`
  *Code:* `Projects::AgentRunsController`

- [x] **AUTOMATION-PHASES-012** — The system SHALL NOT offer a per-item
  override that stops project automation beyond the chosen endpoint.
  *Tests:* `spec/services/automation/manual_start/plan_spec.rb`
  *Code:* `Automation::ManualStart::Plan`

- [x] **AUTOMATION-PHASES-013** — The system SHALL recheck authorization
  before queued work starts, so that disabling a phase, revoking a grant, or
  losing eligibility prevents new unauthorized actions without abruptly
  terminating an already-running action, and retries that start a new execution
  SHALL recheck authorization.
  *Tests:* `spec/services/agent_runs/recheck_issue_eligibility_spec.rb`
  *Code:* `AgentRuns::RecheckIssueEligibility`

- [x] **AUTOMATION-PHASES-014** — The phase model SHALL be gated by the
  default-off `automation_phases` feature flag read through
  `FeatureFlags.enabled?(:automation_phases, project:)`, and while the flag is
  off the pre-existing execution and Inbox policies SHALL remain in force.
  *Tests:* `spec/services/automation/rollout_guard_spec.rb`
  *Code:* `FeatureFlags`, `Automation::RolloutGuard`

- [x] **AUTOMATION-PHASES-015** — The system SHALL derive preview phase
  defaults from each project's currently effective capabilities without
  enabling new automatic work, SHALL NOT grant continuation authorization
  retroactively to existing manual runs, and SHALL report which currently
  label-enabled work would change execution or Inbox relevance before
  activation.
  *Tests:* `spec/services/automation/phases/migration_preview_spec.rb`
  *Code:* `Automation::Phases::MigrationPreview`

- [x] **AUTOMATION-PHASES-016** — Merging SHALL NOT authorize release or
  deployment, Release & Deployment SHALL expose separate subordinate release
  and deployment controls, and enabling one SHALL NOT enable the other.
  *Tests:* `spec/services/automation/phase_settings_spec.rb`,
  `spec/services/automation/effective_policy_notice_spec.rb`
  *Code:* `Automation::PhaseSettings`, `Automation::EffectivePolicyNotice`

- [x] **AUTOMATION-PHASES-017** — The system SHALL treat Paid platform health,
  credential, and safety requests as project-independent so they stay visible
  regardless of a project's Operations phase, and an operations-originated
  incident SHALL hand off work without authorizing issue preparation or coding.
  *Tests:* `spec/services/inbox/phase_ownership_spec.rb`,
  `spec/services/automation/effective_policy_spec.rb`
  *Code:* `Inbox::PhaseOwnership`, `Automation::EffectivePolicy`

- [x] **AUTOMATION-PHASES-018** — Each operational capability SHALL declare its
  signal source, activation policy, response scope, limits, escalation
  behavior, completion meaning, and handoff to other phases, and project
  Operations SHALL describe ownership and handoffs without adding autonomous
  remediation.
  *Tests:* `spec/services/automation/operations/contract_catalog_spec.rb`
  *Code:* `Automation::Operations::ContractCatalog`,
  `docs/intent/automation-phases/operations-ownership.md`
