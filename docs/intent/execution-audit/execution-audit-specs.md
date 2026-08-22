# EARS Specs: Execution Audit Trail

> Testable claims for the append-only execution infrastructure/security
> audit trail (issue #3414, RDR-061). Status markers: `[x]` implemented ·
> `[ ]` active gap · `[D]` deferred. Each ID is a grep target across specs,
> tests, and code (`grep -r EXECUTION-AUDIT-001`).

- [x] **EXECUTION-AUDIT-001** — An `ExecutionAuditEvent` SHALL require
  `event_name` (namespaced, e.g. `container.provisioned`), `event_version`
  (>= 1), and `occurred_at` (auto-assigned when omitted), SHALL reject
  updates or destroys after the initial insert, and SHALL validate that
  `account`, `project`, and `agent_run` are mutually consistent: `project`
  is derived from `agent_run` when missing, `account` is derived from the
  resolved `project` when missing, and an `account` or `project` that does
  not match its associated record's own tenant SHALL be rejected.
  *Tests:* `spec/models/execution_audit_event_spec.rb` ("validations",
  "immutability", "account/project/run consistency (tenant scoping)").
  *Code:* `ExecutionAuditEvent`.

- [x] **EXECUTION-AUDIT-002** — An `ExecutionAuditEvent` SHALL reject
  forbidden metadata key names and any string value (in `metadata`,
  `network_policy`, or in `actor_id`, `runner_key`, `backend`,
  `image_reference`, `image_digest`, `resource_id`, or `correlation_id`)
  that looks secret-shaped, including values nested inside `metadata` or
  `network_policy`, and this check SHALL run in `before_validation`/
  `validate` so it cannot be bypassed by the normal `create!`/`record!`
  constructors.
  *Tests:* `spec/models/execution_audit_event_spec.rb` ("validations",
  "secret redaction").
  *Code:* `ExecutionAuditEvent`, `SecretSafeMetadata`.

- [x] **EXECUTION-AUDIT-003** — `ExecutionAuditEvent` records SHALL be
  queryable by account, project, agent run, runner key, image reference,
  resource (type + id), and correlation id, and SHALL be retained for 400
  days (longer than operational telemetry) via
  `ExecutionAuditEventRetentionJob`, scheduled daily through GoodJob cron.
  *Tests:* `spec/models/execution_audit_event_spec.rb` ("scopes"),
  `spec/jobs/execution_audit_event_retention_job_spec.rb`.
  *Code:* `ExecutionAuditEvent`, `ExecutionAuditEventRetentionJob`,
  `config/initializers/good_job.rb`.

- [ ] **EXECUTION-AUDIT-004** — The execution lifecycle SHALL emit
  `execution.requested`, `execution.queued`, `execution.admitted`,
  `execution.rejected`, `execution.runner_selected`, `execution.image_resolved`,
  `execution.credential_classes_granted`, `execution.network_policy_granted`,
  and `execution.policy_exception_granted` events with secret-free metadata
  sufficient to answer RDR-061 investigation questions. When available, events
  SHALL include Temporal workflow ids, request ids, and persisted runner
  handle ids without logging raw credential material.
  *Tests:* `spec/temporal/activities/create_agent_run_activity_spec.rb`,
  `spec/jobs/process_run_queue_job_spec.rb`,
  `spec/services/containers/provision_spec.rb`.
  *Code:* `Activities::CreateAgentRunActivity`, `ProcessRunQueueJob`,
  `AgentRuns::BindRunner`, `AgentRun`, `Containers::Provision`.

- [ ] **EXECUTION-AUDIT-005** — Resource lifecycle and execution-control paths
  SHALL emit `execution.resource_provision_requested`,
  `execution.resource_provisioned`, `execution.resource_cleanup_failed`,
  `execution.resource_cleanup_retried`,
  `execution.resource_cleanup_succeeded`, and
  `execution.emergency_disable_changed`, linking a resource-ledger row when one
  is available for the provider resource id or runner handle.
  *Tests:* `spec/services/containers/provision_spec.rb`,
  `spec/models/execution_control_spec.rb`.
  *Code:* `Containers::Provision`, `ExecutionControls::RunImpact`.
