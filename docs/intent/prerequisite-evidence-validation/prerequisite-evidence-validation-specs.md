# EARS Specs: Prerequisite Evidence Validation

> Testable claims for the capability-aware, bounded Inbox execution validation
> introduced for [#4643](https://github.com/viamin/paid/issues/4643).
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r PREREQ-EVIDENCE`).

- [x] **PREREQ-EVIDENCE-001** — When an operator opens a blocking
  partial-closeout prerequisite Inbox item (`action_required` entry whose
  notification source is `PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE`)
  for a project they may run agents on, the system SHALL offer a capability
  inspection that reports, through existing runner/provisioner interfaces,
  per-backend execution-host readiness (`Containers::HostReadiness`), the
  `marketplace_tool_sidecars` rollout-flag state, the account service-image
  allowlist, and the account's active `tool` marketplace entries. A missing
  local Docker socket SHALL be reported as that backend's probe result only,
  never as "no usable execution environment".
  *Code:* `app/services/prerequisites/capability_report.rb`,
  `app/controllers/projects/agent_runs_controller.rb#execution_capabilities`,
  `app/views/dashboard/_inbox_detail_prerequisite_validation.html.erb`.
  *Tests:* `spec/services/prerequisites/capability_report_spec.rb`,
  `spec/requests/prerequisite_validation_spec.rb`.

- [x] **PREREQ-EVIDENCE-002** — When an authorized operator starts the
  validation, the system SHALL record one validation for the prerequisite
  owner issue (refusing a second while one is `pending`/`running`), check the
  project budget (`CostBudgets::Check`), snapshot the capability/policy
  inputs, and enqueue bounded execution; a start after a terminal validation
  SHALL create a new generation rather than mutating the prior evidence.
  *Code:* `app/services/prerequisites/start_validation.rb`,
  `app/jobs/prerequisite_validation_job.rb`,
  `app/models/prerequisite_validation.rb`.
  *Tests:* `spec/services/prerequisites/start_validation_spec.rb`,
  `spec/jobs/prerequisite_validation_job_spec.rb`.

- [x] **PREREQ-EVIDENCE-003** — When the validation executes with a healthy
  backend, the system SHALL create a synthetic `AgentRun`
  (`goal: validate_prerequisite`, `synthetic: true`), provision its isolated
  execution environment, clone the pinned checkout
  (`Containers::GitOperations#clone_and_setup_branch`, recording
  `base_commit_sha`), invoke the selected native analyzer through
  `AgentRun#execute_in_execution_environment(..., stream: false)`, and — only
  when the rollout flag is enabled and the selected tool entry's image is
  allowlisted — attach the allowlisted `tool` entry via
  `MarketplaceEntries::AttachToRun`, provision and call its documented endpoint
  from the run container, all through the RDR-073 `McpProvisioner` contract.
  The validation SHALL NOT execute repository or tool code on the control
  plane, expose host shell access, or mount the Docker socket into the agent.
  *Code:* `app/services/prerequisites/execute_validation.rb`,
  `app/models/agent_run.rb` (`validate_prerequisite` goal).
  *Tests:* `spec/services/prerequisites/execute_validation_spec.rb`.

- [x] **PREREQ-EVIDENCE-004** — When no configured backend passes host
  readiness, the system SHALL finish the validation `unavailable` with a
  blocker per unhealthy backend carrying that backend's remediation hint as
  the authorized setup action, and SHALL NOT attempt provisioning. When the
  `marketplace_tool_sidecars` flag is off, the selected tool entry's image is
  not allowlisted, or no active `tool` entry exists, the system SHALL skip the
  sidecar check with a blocker naming the exact authorized enable/allowlist/
  publish action (tenant-settings flag enablement; admin/owner service-image
  allowlisting) and finish `blocked` or `partial` accordingly. The validation
  SHALL NOT enable flags, edit allowlists, or retry an unchanged capability
  failure by itself.
  *Code:* `app/services/prerequisites/execute_validation.rb`,
  `app/services/prerequisites/capability_report.rb`.
  *Tests:* `spec/services/prerequisites/execute_validation_spec.rb`,
  `spec/services/prerequisites/capability_report_spec.rb`.

- [x] **PREREQ-EVIDENCE-005** — The validation SHALL durably record, per check,
  stdout/stderr/exit status (bounded to the pre-commit 10 KB output bound),
  the resolved image reference/digest, the pinned checkout SHA, the selected
  tool identity (entry, version, image, port), the sidecar endpoint URL and
  response shape, and cleanup evidence for the run container and sidecars, and
  SHALL distinguish terminal statuses `succeeded`, `partial`, `failed`,
  `cancelled`, `unavailable`, and `blocked` without collapsing them.
  *Code:* `app/services/prerequisites/execute_validation.rb`,
  `app/models/prerequisite_validation.rb`.
  *Tests:* `spec/services/prerequisites/execute_validation_spec.rb`,
  `spec/models/prerequisite_validation_spec.rb`.

- [x] **PREREQ-EVIDENCE-006** — The validation SHALL link its evidence to the
  prerequisite owner issue and render it on the prerequisite's Inbox item for
  canonical evidence assessment, and SHALL NOT resolve the prerequisite
  notification, close or reopen the owner issue, publish a source-closing
  reference, or mutate `paid_state`; missing execution evidence keeps the
  owner open (#4604/#4631 ownership).
  *Code:* `app/services/prerequisites/execute_validation.rb`,
  `app/views/dashboard/_inbox_detail_prerequisite_validation.html.erb`,
  `app/views/dashboard/_inbox_detail_action_required.html.erb`.
  *Tests:* `spec/services/prerequisites/execute_validation_spec.rb`,
  `spec/requests/prerequisite_validation_spec.rb`.

- [x] **PREREQ-EVIDENCE-007** — Progress, cancellation, and idempotent retry
  SHALL work from the Inbox UI, the controller API, and the MCP tools
  (`start_prerequisite_validation`, `cancel_prerequisite_validation`,
  confirmation-gated, authorized by the same project `run_agent?` policy).
  Cancellation SHALL preserve collected evidence and still run cleanup. A
  terminal validation whose stored `scope_digest` no longer matches the
  current policy inputs SHALL be presented as stale with an explicit
  revalidation offer, not as current evidence.
  *Code:* `app/services/prerequisites/cancel_validation.rb`,
  `app/mcp/tools/start_prerequisite_validation.rb`,
  `app/mcp/tools/cancel_prerequisite_validation.rb`,
  `app/models/prerequisite_validation.rb`.
  *Tests:* `spec/services/prerequisites/cancel_validation_spec.rb`,
  `spec/requests/prerequisite_validation_spec.rb`,
  `spec/mcp/tools/start_prerequisite_validation_spec.rb`.

- [x] **PREREQ-EVIDENCE-008** — The delivered behavior SHALL be validated for:
  a host-without-Docker backend alongside a compatible backend; no compatible
  backend at all; the tool flag off; a denied (non-allowlisted) tool image; a
  cancelled/failed execution; and a successful native-plus-sidecar lifecycle
  with cleanup evidence — each producing the distinct status and blocker
  required above, without control-plane execution of untrusted code.
  *Tests:* `spec/services/prerequisites/execute_validation_spec.rb`,
  `spec/services/prerequisites/capability_report_spec.rb`,
  `spec/requests/prerequisite_validation_spec.rb`.
