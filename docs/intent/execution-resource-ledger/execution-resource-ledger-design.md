---
parent: PAID
prefix: RESOURCE-LEDGER
---

# Low-Level Design: Execution Resource Ledger

> Companion to the high-level design (`docs/high-level-design.md`) and
> [RDR-060](../../rdrs/RDR-060-external-execution-resource-ledger.md). Covers
> the durable data model for tracking externally provisioned execution
> resources through their provisioning-to-cleanup lifecycle.

## Purpose

Paid provisions resources outside its own database on behalf of agent runs:
containers, browser/MCP sidecars, workspace volumes, networks, preview
tunnels, and temporary storage. Today there is no single durable record of
what was provisioned, for whom, and whether it was ever cleaned up — leaked or
orphaned resources are invisible until a provider bill or a manual audit
surfaces them. `ExecutionResourceLedgerEntry` closes that gap with a ledger
row per provisioned resource that survives independently of the runtime
process that created it.

This is a ledger of *execution resources* only, scoped to what Paid itself
provisions for agent runs — it is explicitly not a general-purpose cloud CMDB
covering arbitrary infrastructure.

## Scope of this segment

This segment covers Phase 1 of RDR-060's implementation plan: the
`execution_resource_ledger_entries` table and the `ExecutionResourceLedgerEntry`
model with lifecycle states, validation, and tenant scoping. Idempotent
provisioning/cleanup integration (RDR-060 phase 2, #3352), reconciliation
against provider state (#3411), and wiring into the runner/ledger execution
path (#3410) remain future work tracked by those issues.

## Data model

Each row identifies:

- **who** — `account`, `project` (required), and an optional `agent_run` +
  `run_attempt`, since some resources (e.g. a pre-warmed pool entry) exist
  before or independent of a specific run.
- **what** — `runner_type` (e.g. `docker`, `kubernetes`) and optional
  `backend` (e.g. `local`, `ecs`) identify the execution runner that owns the
  resource; `resource_kind` classifies it as one of `primary_environment`,
  `service`, `sidecar` (covering both browser and MCP sidecars), `workspace`,
  `network`, `preview_tunnel`, or `temporary_storage`.
  `provider_resource_id` is the provider-assigned identifier (container ID,
  volume ID, tunnel ID, ...), unique per `(runner_type, backend)` when present.
- **ownership metadata** — `tags`, a jsonb map for non-secret
  provider-ownership labels (e.g. `paid.managed`, `paid.account_id`). Scanned
  at validation time via the shared `SecretSafeMetadata` concern (applied to
  `tags` instead of its default `metadata` column) so a caller can never
  persist secret-shaped tag values.
- **runner handle** — `runner_handle`, a jsonb snapshot of an
  `ExecutionRunners::RunnerHandle` (`runner_type`, `identifier`, `host`,
  `workspace_ref`, `metadata`), giving reconciliation and cleanup code enough
  information to locate the resource without re-deriving it.
- **lifecycle** — `status` plus per-transition timestamps (`activated_at`,
  `cleanup_requested_at`, `deleted_at`, `orphaned_at`, `cleanup_failed_at`) and
  cleanup retry bookkeeping (`cleanup_attempts`, `cleanup_last_attempted_at`,
  `cleanup_last_error`).

## Lifecycle

Status states, mirroring the GitHub issue's acceptance criteria:

- `provisioning` — creation requested, not yet confirmed.
- `active` — confirmed provisioned and in use.
- `cleanup_pending` — cleanup requested, not yet confirmed.
- `deleted` — cleanup confirmed complete (terminal).
- `orphaned` — reconciliation found a resource with no live owner.
- `cleanup_failed` — a cleanup attempt failed; retryable back into
  `cleanup_pending`.

Allowed transitions: `provisioning -> {active, cleanup_pending, orphaned}`,
`active -> {cleanup_pending, orphaned}`, `cleanup_pending -> {deleted,
cleanup_failed}`, `cleanup_failed -> {cleanup_pending, deleted}`, `orphaned ->
{cleanup_pending, deleted}`. `deleted` is terminal. The model enforces this
via `ALLOWED_STATUS_TRANSITIONS`, validated on every update and exposed
through idempotent bang methods (`activate!`, `request_cleanup!`,
`mark_deleted!`, `mark_orphaned!`, `record_cleanup_failure!`) so retrying a
transition (e.g. a job re-running after a crash) never double-stamps a
timestamp or raises.

RDR-060 itself proposes a richer 8-state lifecycle
(`intent_created -> provisioning -> provisioned -> cleanup_requested ->
cleaned -> verified_gone`, plus `orphaned`/`leak_suspected`); the GitHub
issue's 6-state list is the authoritative scope for this phase and is what is
implemented here. The RDR's lifecycle can be reconciled or revised as later
phases land.

## Tenant scoping

`account_id` is the RLS tenant key, enforced by an inline `tenant_isolation`
policy on the table (matching the pattern used by `execution_audit_events`
and `egress_security_events`). Validation mirrors `ExecutionAuditEvent`:
`account` is derived from `project` when omitted, and cross-tenant
mismatches between `account`/`project`/`agent_run` are rejected before
persistence.
