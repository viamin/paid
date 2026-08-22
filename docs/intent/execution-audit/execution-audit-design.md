---
parent: PAID
prefix: EXECUTION-AUDIT
---

# Low-Level Design: Execution Audit Trail

> Companion to the high-level design (`docs/high-level-design.md`) and
> `docs/rdrs/RDR-058-execution-authority-network-and-isolation.md`. This
> segment implements issue #3414 (RDR-061): an append-only, application-level
> audit trail for execution-infrastructure and security-relevant events —
> distinct from operational logs (`AgentRunLog`) and telemetry
> (`RunnerAuthAttempt`, container metrics).

## Purpose

Operators and incident responders need to answer "what security-relevant
thing happened to this run's execution environment, and who/what caused
it" — credential-class resolution, network policy application, image and
resource provisioning — without wading through free-text operational logs.
`ExecutionAuditEvent` records these as structured, immutable rows that are
queryable by run, project, account, runner, image, and resource, and that
can never carry raw secret material.

## Shipped Behavior

- **Append-only record.** `ExecutionAuditEvent` has no `updated_at` and is
  never modified or destroyed through the model lifecycle after creation;
  it is not logidze-tracked (logidze is for mutable config, not audit
  trails — see `CLAUDE.md`). Retention is enforced separately (see below),
  not by a mutable/soft-delete state.
- **Required identity fields.** Every event carries `event_name` (namespaced,
  e.g. `container.provisioned`), `event_version`, and `occurred_at`
  (auto-assigned to `Time.current` when omitted).
- **Tenant scoping and consistency.** `account`, `project`, and `agent_run`
  are cross-validated: `project` is derived from `agent_run` when omitted,
  `account` is derived from the resolved `project` when omitted, and
  mismatches (an `account` that doesn't match the `project`'s account, or a
  `project` that doesn't match the `agent_run`'s project) are rejected.
  The table also carries forced row-level security scoped to `account_id`,
  matching the tenant-isolation pattern used by other tenant-scoped tables.
- **Execution context fields.** `runner_key`, `backend`, `image_reference`,
  `image_digest`, `credential_classes` (validated against the same
  credential-class vocabulary as `ExecutionRunners::NetworkingPolicy`'s
  modes, plus `none`), `network_policy` (a JSON object mirroring
  `NetworkingPolicy#mode`/`#firewall`/`#allow_destinations`), and
  `resource_type` together with `resource_id`, and `correlation_id` are all
  queryable via dedicated scopes (`for_account`, `for_project`,
  `for_agent_run`, `for_runner_key`, `for_image_reference`, `for_resource`,
  `for_correlation_id`) plus a `recent` ordering scope.
- **Secret-free by construction.** `SecretSafeMetadata` (shared with
  `RunnerAuthAttempt`) rejects forbidden metadata key names and any
  string value that looks secret-shaped, recursively, in `metadata` and
  `network_policy`. The same secret-shape check also runs against
  `actor_id`, `runner_key`, `backend`, `image_reference`, `image_digest`,
  `resource_id`, and `correlation_id`. Because this runs in
  `before_validation`/`validate`, it cannot be bypassed through the normal
  `create!`/`record!` constructors — an attempt to smuggle raw credential
  material through any of these fields raises `ActiveRecord::RecordInvalid`
  and persists nothing.
- **Retention.** `ExecutionAuditEventRetentionJob` (scheduled daily via
  GoodJob cron) deletes events older than 400 days — longer than
  operational telemetry, to support incident investigation and compliance
  review windows (see `docs/DATA_MODEL.md` "Data Retention").

## What This Is Not

- **Not a replacement for `AgentRunLog` or `RunnerAuthAttempt`.**
  Free-text operational output stays in `AgentRunLog`; auth-specific
  materialization/harvest/lease telemetry stays in `RunnerAuthAttempt`
  (see `docs/intent/subscription-runner-auth/`). `ExecutionAuditEvent` is
  for discrete, structured security/infrastructure events that call sites
  choose to record explicitly.
- **Not a capability-grant or network-policy engine.** It records the
  *outcome* of credential-class and network-policy decisions made
  elsewhere (RDR-058's `ExecutionRunners::NetworkingPolicy`), it does not
  make those decisions.
- **Not wired into every execution call site yet.** This segment ships the
  model, validations, retention job, and factory/spec scaffolding.

## Lifecycle Instrumentation

Execution lifecycle call sites record the RDR-061 investigation events through
`ExecutionAuditEvent.record!`, with the call-site wiring kept thin and the
event normalization shared in one helper layer.

- **Admission lifecycle.** Run creation and dequeue admission emit
  `execution.requested`, `execution.queued`, `execution.admitted`, and
  `execution.rejected` so operators can see when a run entered the system,
  when it became runnable, and when capacity or policy blocked execution.
- **Selection and grant decisions.** Runner binding emits
  `execution.runner_selected`; authority/network decisions emit
  `execution.credential_classes_granted`, `execution.network_policy_granted`,
  and `execution.policy_exception_granted` with secret-free snapshots of the
  granted authority, unrestricted-network intent, and preview-ingress or
  other explicit exception grants.
- **Provisioning and cleanup.** Container/image provisioning emits
  `execution.image_resolved`, `execution.resource_provision_requested`, and
  `execution.resource_provisioned`; cleanup emits
  `execution.resource_cleanup_failed`, `execution.resource_cleanup_retried`,
  and `execution.resource_cleanup_succeeded`, linking a matching
  `ExecutionResourceLedgerEntry` when one is discoverable from the run and
  provider resource id.
- **Execution controls.** Emergency or capacity kill-switch toggles emit
  `execution.emergency_disable_changed` in the execution-audit stream in
  addition to the existing account activity trail so RDR-061 investigations do
  not need to join two audit models to reconstruct lifecycle causality.

Each emitted event includes the common correlation identifiers when available:
Temporal workflow id, request id, persisted runner handle id, and resource
ledger id. Secret-shaped values are still rejected by the model-layer scans, so
call sites pass only class names, ids, digests, and other non-secret metadata.
