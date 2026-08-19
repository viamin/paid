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
