# RDR-060 Audit Report — 2026-08-18 Closeout

- **RDR**: [RDR-060: External Execution Resource Ledger](RDR-060-external-execution-resource-ledger.md)
- **Audit date**: 2026-08-18
- **Umbrella issue**: [#3420](https://github.com/viamin/paid/issues/3420) (remains open pending the remaining RDR-060 gaps)
- **Conclusion**: Partially Implemented. The foundational resource lifecycle
  management infrastructure is shipped and covered by passing spec suites (see
  [Validation Evidence](#validation-evidence)). The per-criterion verdicts below
  qualify *what is currently enforced*; the core ledger data model
  ([#3409](https://github.com/viamin/paid/issues/3409)), runner/ledger
  integration ([#3410](https://github.com/viamin/paid/issues/3410)),
  reconciliation ([#3411](https://github.com/viamin/paid/issues/3411)),
  idempotent lifecycle ([#3352](https://github.com/viamin/paid/issues/3352)),
  and runner conformance suite
  ([#3358](https://github.com/viamin/paid/issues/3358)) are all open — see
  [Blocking Dependencies Reconciliation](#blocking-dependencies-reconciliation).

## Validation Evidence

Executed during the 2026-08-18 closeout audit recorded against umbrella issue
[#3420](https://github.com/viamin/paid/issues/3420). The umbrella remains open
because the remaining RDR-060 gaps are still tracked in its blocking
dependencies. All suites passed in full; no failures, no pending examples.

```console
$ bundle exec rspec spec/jobs/agent_run_resource_janitor_job_spec.rb
12 examples, 0 failures

$ bundle exec rspec spec/models/worktree_spec.rb
25 examples, 0 failures

$ bundle exec rspec spec/services/execution_runners_spec.rb \
    spec/services/execution_runners/
124 examples, 0 failures

$ bundle exec rspec spec/models/docker_host_spec.rb
6 examples, 0 failures
```

## Acceptance Criteria vs. Shipped Implementation

### Criterion 1: Externally provisioned execution resources can be represented in the ledger

**Status**: Partial.

**Shipped**:

Resources are tracked across multiple subsystems that collectively record
the lifecycle of every execution resource Paid provisions:

- **`agent_runs`**: `container_id` (Docker container identifier),
  `container_host` (backend host), `runner_handle` (jsonb — carries
  `runner_type`, `identifier`, `host`, `workspace_ref`, `metadata`),
  `external_metadata` (carries `planned_container_host` for admission
  decisions), `container_retained_until` (preview session retention).
- **`container_pool_entries`**: Warm-pool containers with lifecycle states
  (`warming`, `warm`, `claimed`, `error`). Tracks `container_id`,
  `container_host`, `workspace_volume`, `image`, `network`. Carries
  `runner_handle` for recovery.
- **`worktrees`**: Git worktree lifecycle (`active`, `cleaned`,
  `cleanup_failed`). Scopes: `active`, `cleaned`, `stale(duration)`,
  `orphaned`.
- **`docker_hosts`**: Multi-backend host registry (`local`, `remote`,
  `swarm`) with readiness states (`unknown`, `ready`, `failing`, `disabled`,
  `draining`). Tenant-scoped via `account_id`.

**What is missing**:

A unified `execution_resource_ledger_entries` table that consolidates all
resource types into a single queryable model with standardized lifecycle
states. The current distributed tracking requires joining multiple tables
and has no single query surface for "all resources provisioned for account X."

**Evidence**:

- `app/models/agent_run.rb` — `container_id`, `container_host`, `runner_handle` columns
- `app/models/container_pool_entry.rb` — warm-pool lifecycle states
- `app/models/worktree.rb` — worktree lifecycle tracking
- `app/models/docker_host.rb` — multi-backend host registry
- `app/services/execution_runners.rb:249-285` — `RunnerHandle` Data class with `from_record`/`from_json` recovery
- `db/schema.rb` — table definitions for all four models

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/jobs/agent_run_resource_janitor_job_spec.rb` — container and volume cleanup lifecycle
- `spec/models/worktree_spec.rb` — worktree state transitions and scope queries
- `spec/models/docker_host_spec.rb` — host readiness tracking
- `spec/services/execution_runners_spec.rb` — `RunnerHandle` serialization and recovery

**Verdict**: Partial — infrastructure exists but not unified into a ledger.

---

### Criterion 2: Provider resources carry stable Paid ownership tags

**Status**: Partial.

**Shipped**:

- Docker workspace volumes use a deterministic naming convention:
  `paid-workspace-{agent_run_id}`, and are also labeled at creation time via
  `volume_options` (`provision.rb:2450-2462`): `paid.managed`,
  `paid.resource`, `paid.project_id`, plus `paid.agent_run_id` or
  `paid.container_pool_entry_id`. These labels are applied through
  `backend.create_volume(@workspace_volume, volume_options)`
  (`provision.rb:2264`).
- Containers are labeled via `container_labels` (`provision.rb:2464`):
  `paid.project_id`, and either `paid.agent_run_id` or
  `paid.container_pool_entry_id`/`paid.container_pool`, applied through
  `"Labels" => container_labels` in the container config
  (`provision.rb:2522`).

**What is missing**:

- No `paid.account_id`, `paid.created_at`, or `paid.resource_kind` labels
  (the full RDR-060 tag set) are applied — only the subset above.
- No tag/label strategy for future cloud providers.

**Evidence**:

- `app/jobs/agent_run_resource_janitor_job.rb:17` — `VOLUME_PREFIX = "paid-workspace-"` (naming convention, not a label)
- `app/services/containers/provision.rb:2450-2462` — `volume_options` applies ownership labels to volumes
- `app/services/containers/provision.rb:2464-2484` — `container_labels` applies ownership labels to containers

**Verdict**: Partial — container and volume labels are applied during provisioning, but the full RDR-060 tag set (`paid.account_id`, `paid.created_at`, `paid.resource_kind`) is not yet complete. Tracked in #3410.

---

### Criterion 3: Crash-window provisioning intents exist before provider create calls

**Status**: Gap.

**Shipped**:

- `RunnerHandle` is persisted to `agent_runs.runner_handle` *after* successful
  provisioning (#3346). This enables recovery after worker crash/failover
  but does not protect the crash window *during* the provider create call.
- `external_metadata.planned_container_host` records the admission decision
  before provisioning, providing a hint for cleanup, but this is not a formal
  provisioning intent record.

**What is missing**:

- No `intent_created` record is written to any table before calling the
  Docker/provider create API.
- If the process crashes between the provider create call returning and
  persisting `runner_handle`, the created resource has no record and will
  leak.

**Evidence**:

- `app/services/execution_runners.rb:249-285` — `RunnerHandle` definition
- `app/services/execution_runners/local_docker_runner.rb` — `provision` writes `RunnerHandle` after container creation
- `app/services/containers/provision.rb` — `planned_container_host` stored in `external_metadata` pre-provision

**Verdict**: Gap — post-provision recovery exists; pre-provision intent does not.

---

### Criterion 4: Reconciliation can detect ledger/provider drift and retry cleanup

**Status**: Gap.

**Shipped**:

- `AgentRunResourceJanitorJob` retries failed cleanup with polynomial
  backoff (3 attempts) on Docker errors. This handles transient failures
  during cleanup but does not detect drift.
- `EnqueueJanitorActivity` provides second-chance cleanup outside the
  Temporal workflow lifecycle for transient Docker daemon outages.
- Container pool entries have stale detection (15-minute threshold for
  `warming` entries).

**What is missing**:

- No periodic job lists provider resources and compares them against
  application records.
- No orphan detection: Docker containers that exist on a host without a
  matching `agent_runs.container_id` or `container_pool_entries.container_id`
  record are not discovered.
- No drift reporting or alerting.

**Evidence**:

- `app/jobs/agent_run_resource_janitor_job.rb:15` — `retry_on Docker::Error::DockerError`
- `app/temporal/activities/enqueue_janitor_activity.rb` — second-chance cleanup enqueue
- `app/models/container_pool_entry.rb` — `stale` scope for warming entries

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/jobs/agent_run_resource_janitor_job_spec.rb` — retry behavior on Docker errors

**Verdict**: Gap — retry-based cleanup exists; active drift detection does not.

---

### Criterion 5: Providers without tag/list support degrade explicitly and safely

**Status**: Gap.

**Shipped**:

- `Containers::Backends::Base` provides minimal capability signaling
  (`supports_host_paths?`, `remote?`, `owns_host?`).
- The runner interface (`ExecutionRunners::Base`) defines `provision`,
  `start`, `running?`, `cancel`, `cleanup` — but no `supports_tags?` or
  `supports_list?` capability declarations.

**What is missing**:

- No capability model for tag/list support on runners or backends.
- No explicit degradation path when a provider cannot tag or list resources.
- No logged warnings or dashboard visibility for capability gaps.

**Evidence**:

- `app/services/containers/backends/base.rb` — capability predicates (no tag/list support)
- `app/services/execution_runners.rb` — runner interface (no tag/list capability)

**Verdict**: Gap — no degradation model exists.

---

### Criterion 6: Existing Docker janitors still work during migration

**Status**: Implemented.

**Shipped**:

The existing Docker cleanup infrastructure is fully functional and tested:

- `AgentRunResourceJanitorJob` handles container removal (via backend API)
  and volume removal (by deterministic name `paid-workspace-{id}`). It
  resolves the cleanup host through `runner_handle`, `container_host`, or
  `external_metadata["planned_container_host"]` fallback chain.
- `CleanupContainerActivity` calls `agent_run.cleanup_container(force: true)`
  as a Temporal workflow activity with phase tracking.
- `CleanupWorktreeActivity` transitions worktree status from active to
  cleaned as a database-only operation.
- `EnqueueJanitorActivity` enqueues the janitor job as a maintenance
  background job for second-chance cleanup outside the workflow lifecycle.
- Legacy `worktree_path` (bind mount) runs skip volume cleanup correctly.
- Container retention for preview sessions is respected (`container_retained?`
  guard).

**Evidence**:

- `app/jobs/agent_run_resource_janitor_job.rb` — full cleanup implementation
- `app/temporal/activities/cleanup_container_activity.rb` — Temporal activity
- `app/temporal/activities/cleanup_worktree_activity.rb` — worktree cleanup
- `app/temporal/activities/enqueue_janitor_activity.rb` — second-chance enqueue

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/jobs/agent_run_resource_janitor_job_spec.rb` — 12 examples covering
  container cleanup, volume cleanup, skip-when-retained, legacy worktree
  handling, host resolution fallback chain

**Verdict**: Satisfied.

---

## Gaps

The following gaps remain after this audit. Each is owned by an open issue —
none is "implicitly satisfied" by the shipped code.

1. **Unified resource ledger data model** — tracked in
   [#3409](https://github.com/viamin/paid/issues/3409). The current distributed
   tracking across `agent_runs`, `container_pool_entries`, `worktrees`, and
   `docker_hosts` provides the necessary data but lacks a single query surface,
   standardized lifecycle states, and the provisioning intent capability. This
   is the foundational gap that gates criteria 2-5.

2. **Complete provider ownership tag set** — tracked in
   [#3410](https://github.com/viamin/paid/issues/3410). Docker containers and
   volumes are already labeled with `paid.managed`, `paid.resource`,
   `paid.project_id`, and `paid.agent_run_id`/`paid.container_pool_entry_id`
   during provisioning (`app/services/containers/provision.rb`), but the full
   RDR-060 tag set (`paid.account_id`, `paid.created_at`,
   `paid.resource_kind`) is not yet applied, and there is no tag/label
   strategy for future cloud providers.

3. **Reconciliation against provider state** — tracked in
   [#3411](https://github.com/viamin/paid/issues/3411). No periodic drift
   detection exists. The janitor job retries cleanup on failure but does not
   discover orphaned resources that have no application record.

4. **Idempotent execution lifecycle and crash recovery** — tracked in
   [#3352](https://github.com/viamin/paid/issues/3352). Post-provision recovery
   via `RunnerHandle` is implemented (#3346), but pre-provision intents and
   idempotent provision/cleanup operations using ledger state are not.

5. **Runner conformance suite** — tracked in
   [#3358](https://github.com/viamin/paid/issues/3358). No conformance suite
   validates that runners correctly integrate with the ledger, apply tags, or
   support reconciliation queries.

Items 1-5 are tracked in their respective issues; this audit does not file
new child issues because each already names the RDR-060 work item. The
umbrella status of
[RDR-060](RDR-060-external-execution-resource-ledger.md) remains
**Partially Implemented** as long as any of gaps 1-4 are open.

## Child Issues

None filed by this audit. Existing blocking dependencies on the closeout
issue [#3420](https://github.com/viamin/paid/issues/3420) are sufficient:

- [#3409](https://github.com/viamin/paid/issues/3409) — Add execution resource
  ledger data model. **Open**. See gap 1 above.
- [#3410](https://github.com/viamin/paid/issues/3410) — Integrate runners with
  ledger intents and provider tags. **Open**. See gap 2 above.
- [#3411](https://github.com/viamin/paid/issues/3411) — Reconcile execution
  resource ledger against provider state. **Open**. See gap 3 above.
- [#3352](https://github.com/viamin/paid/issues/3352) — Idempotent execution
  lifecycle and crash recovery for external resources. **Open**. See gap 4
  above.
- [#3344](https://github.com/viamin/paid/issues/3344) — Abstract logging,
  status, cancellation, and cleanup behind the runner. **Closed**. Its work
  (`ExecutionRunners::Base` interface, concrete runner implementations) is
  the shipped evidence for the runner abstraction layer that the ledger will
  integrate with.
- [#3346](https://github.com/viamin/paid/issues/3346) — Persist runner handle
  for Temporal workflow recovery and failover. **Closed**. Its work
  (`RunnerHandle` Data class, jsonb persistence on `agent_runs`) provides
  the post-provision recovery mechanism that the ledger will extend with
  pre-provision intents.
- [#3358](https://github.com/viamin/paid/issues/3358) — Runner conformance
  suite and provider comparison benchmark methodology. **Open**. See gap 5
  above.

## Blocking Dependencies Reconciliation

The closeout issue [#3420](https://github.com/viamin/paid/issues/3420) lists
seven blocking dependencies. This section reconciles each against the
2026-08-18 audit.

| Dependency | State | Reconciliation |
|------------|-------|----------------|
| [#3409](https://github.com/viamin/paid/issues/3409) — ledger data model | Open | Remaining RDR-060 scope (gap 1). The foundational table, model, and state machine are not implemented. This is the load-bearing gap that gates the other four. |
| [#3410](https://github.com/viamin/paid/issues/3410) — runner/ledger integration with provider tags | Open | Remaining RDR-060 scope (gap 2). Runner provision/cleanup paths do not write ledger entries, and provider resources carry only a partial ownership tag set (`paid.managed`, `paid.resource`, `paid.project_id`, `paid.agent_run_id`/`paid.container_pool_entry_id`) — missing `paid.account_id`, `paid.created_at`, `paid.resource_kind`. |
| [#3411](https://github.com/viamin/paid/issues/3411) — reconciliation against provider state | Open | Remaining RDR-060 scope (gap 3). No periodic drift detection or orphan discovery exists. The janitor job handles per-run cleanup retries but does not reconcile against the provider's resource inventory. |
| [#3352](https://github.com/viamin/paid/issues/3352) — idempotent execution lifecycle | Open | Remaining RDR-060 scope (gap 4). Post-provision recovery via `RunnerHandle` is shipped (#3346), but pre-provision intents and idempotent state transitions are not. |
| [#3344](https://github.com/viamin/paid/issues/3344) — abstract logging/status/cleanup behind runner | Closed | Satisfied. The `ExecutionRunners::Base` interface and `LocalDockerRunner` implementation provide the integration surface that ledger operations will hook into. |
| [#3346](https://github.com/viamin/paid/issues/3346) — persist runner handle for recovery | Closed | Satisfied. `RunnerHandle` persistence on `agent_runs.runner_handle` enables post-provision crash recovery. The ledger extends this with pre-provision intent records. |
| [#3358](https://github.com/viamin/paid/issues/3358) — runner conformance suite | Open | Remaining RDR-060 scope (gap 5). No conformance suite validates ledger integration, tag application, or reconciliation query support across runners. |

Because five of seven blocking dependencies are open and all five represent
remaining RDR-060 scope, the "Partially Implemented" verdict is
load-bearing: the shipped code closes the *cleanup and recovery* layer but
the *unified ledger*, *provisioning intents*, *ownership tags*, and *active
reconciliation* are not complete. This audit recommends keeping the umbrella
open and re-running the closeout after the remaining gaps land.
