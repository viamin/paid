# EARS Specs: Execution Resource Ledger

> Testable claims for RDR-060 phase 1 (execution resource ledger data model).
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each
> ID is a grep target across specs, tests, and code
> (`grep -r RESOURCE-LEDGER-001`).

- [x] **RESOURCE-LEDGER-001** — The system SHALL persist a durable ledger row
  per externally provisioned execution resource, scoped to `account` and
  `project` (required) with an optional `agent_run` and `run_attempt`, and
  SHALL classify each row by `resource_kind` into one of
  `primary_environment`, `service`, `sidecar`, `workspace`, `network`,
  `preview_tunnel`, or `temporary_storage`, rejecting any other value.
  Whenever `provider_resource_id` is present, the system SHALL also enforce
  uniqueness per `(runner_type, backend)`, including rows whose `backend` is
  `NULL`.
  *Tests:* `spec/models/execution_resource_ledger_entry_spec.rb`
  *Code:* `ExecutionResourceLedgerEntry`,
  `db/migrate/20260821103345_create_execution_resource_ledger_entries.rb`,
  `db/migrate/20260821135405_fix_execution_resource_ledger_provider_identity_index.rb`

- [x] **RESOURCE-LEDGER-002** — The system SHALL enforce a fixed lifecycle
  state machine on `status` (`provisioning`, `active`, `cleanup_pending`,
  `deleted`, `orphaned`, `cleanup_failed`) where only documented transitions
  are permitted, `deleted` is terminal, and idempotent bang methods
  (`activate!`, `request_cleanup!`, `mark_deleted!`, `mark_orphaned!`,
  `record_cleanup_failure!`) drive the transitions without re-stamping
  timestamps or raising when called on a record already in the target state.
  *Tests:* `spec/models/execution_resource_ledger_entry_spec.rb`
  *Code:* `ExecutionResourceLedgerEntry`

- [x] **RESOURCE-LEDGER-003** — The system SHALL reject a ledger row whose
  `account` does not match its `project`'s account, or whose `project` does
  not match its `agent_run`'s project, and SHALL derive `account` from
  `project` when omitted. Row-level security SHALL enforce tenant isolation
  on `account_id` at the database layer.
  *Tests:* `spec/models/execution_resource_ledger_entry_spec.rb`
  *Code:* `ExecutionResourceLedgerEntry`,
  `db/migrate/20260821103345_create_execution_resource_ledger_entries.rb`

- [x] **RESOURCE-LEDGER-004** — `tags` and `runner_handle` SHALL each be
  validated as an object and scanned for secret-shaped keys/values using the
  shared `SecretSafeMetadata` scan, rejecting persistence (even via the bare
  `create!` constructor) when either carries forbidden keys or
  credential-shaped values — `runner_handle` serializes
  `ExecutionRunners::RunnerHandle`, whose metadata can include container
  environment variables, so it gets the same scan as `tags`.
  *Tests:* `spec/models/execution_resource_ledger_entry_spec.rb`
  *Code:* `ExecutionResourceLedgerEntry`, `SecretSafeMetadata`

- [x] **RESOURCE-LEDGER-007** — Deleting the owning `project` or `agent_run`
  SHALL NOT delete a ledger row: the foreign keys use `on_delete: :nullify`
  (not `:cascade`) and `AgentRun#execution_resource_ledger_entries` uses
  `dependent: :nullify`, so rows the ledger exists to track remain queryable
  for reconciliation after their creating project/run is gone. `account`
  remains `on_delete: :cascade` as the RLS tenant key.
  *Tests:* `spec/models/execution_resource_ledger_entry_spec.rb`,
  `spec/models/agent_run_spec.rb`
  *Code:* `db/migrate/20260821103345_create_execution_resource_ledger_entries.rb`,
  `AgentRun`

- [ ] **RESOURCE-LEDGER-005** — Provisioning and cleanup activities SHALL
  create and transition ledger rows idempotently as part of the actual
  resource lifecycle (container provisioning, sidecar startup, tunnel
  teardown, etc.), rather than the ledger existing only as a standalone data
  model. (RDR-060 phase 2, tracked by #3352, #3410.)

- [ ] **RESOURCE-LEDGER-006** — A reconciliation process SHALL periodically
  compare ledger rows against live provider state, marking resources with no
  live owner as `orphaned` and surfacing `cleanup_failed` rows for retry or
  alerting. (RDR-060 phase 3+, tracked by #3411.)
