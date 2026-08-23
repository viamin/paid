---
parent: PAID
prefix: CONTAINER-RUNTIME
---

# Low-Level Design: Container Runtime

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> implemented container RDRs [RDR-004](../../rdrs/RDR-004-container-isolation.md),
> [RDR-019](../../rdrs/RDR-019-remote-container-execution.md),
> [RDR-020](../../rdrs/RDR-020-service-container-architecture.md),
> [RDR-043](../../rdrs/RDR-043-zero-config-docker-capacity-autoscaling.md), and
> [RDR-048](../../rdrs/RDR-048-multi-host-docker-backend-support.md), and
> [RDR-057](../../rdrs/RDR-057-remote-execution-data-contract.md), and
> [RDR-062](../../rdrs/RDR-062-execution-network-policy-intent.md). This
> segment also records the still-shipped legacy residue from superseded
> [RDR-005](../../rdrs/RDR-005-git-worktree-management.md).

## Purpose

Paid's container runtime is the shipped boundary between the control plane and
untrusted agent execution. The current model is no longer "host worktree bind
mounted into a local container for every run." Normal agent runs now use a
backend-selected Docker container, a per-run named workspace volume, and an
in-container clone, while multi-host placement, service-container routing, and
capacity admission all operate against the selected backend.

This segment captures the current runtime contract so brownfield LID coverage
matches the implementation rather than the older worktree-first design text.

## Runtime Contract

### Isolation and workspace provisioning

`Containers::Provision` owns the normal agent-run container lifecycle. It:

- validates backend compatibility before provisioning,
- creates or reuses the backend-selected Docker network,
- uses a per-run named Docker volume (`paid-workspace-<agent_run_id>`) when
  `worktree_path` is blank so the repo clone happens inside the container,
- seeds runner credentials and applies network restrictions after start, and
- records the backend-owned `container_host` only from the created container.

An explicit `worktree_path` is still accepted as a legacy compatibility input
for bind-mount and maintenance flows, but host-created worktrees are no longer
the default execution workspace for normal agent runs.

### Host selection and lifecycle routing

`Containers::ResolveHostForRun` converts explicit or preferred host choices
into run attributes. Restricted/proxy runs consider hosts whose primary
`paid_agent` network is ready; unrestricted subscription-auth and
direct-outbound runs additionally require the `paid_internal` infra network.
`Containers::BackendScheduler` then filters candidate hosts by compatibility
and readiness, with optional first-healthy or capacity-aware fallback.

In multi-host mode, `container_host` is intentionally not treated as an eager
claim-time placement field. During the queue claim window, the admitted host is
stored in `external_metadata["planned_container_host"]`, and the real
`container_host` is persisted only once a backend creates or claims a concrete
resource.

`AgentRun.active_count_for_host` and `AgentRun#workspace_volume_host` mirror
that rule: before a real container records ownership, per-host admission and
workspace-volume cleanup both route by the planned host metadata instead of
charging blank rows to the local backend.

### Service-container orchestration

`Containers::ServiceProvisioner` manages project service containers on the same
backend/network as the agent run. It records `service_container_ids` on the run
before startup so concurrent cleanup can count the run, reuses healthy running
containers when possible, generates per-service environment variables, and only
stops containers when no in-flight runs still reference them.

The backend decision for service containers follows the selected run backend or
the persisted service-container host so reuse, metrics, reconciliation, and
cleanup stay routed to the daemon that actually owns the container.

### Capacity snapshots and admission

`Capacity::DockerSnapshot` is the per-backend Docker visibility layer for
runtime admission. It classifies visible Docker usage into four buckets:

- Paid control plane
- Paid agent containers
- Paid service containers
- other Docker workloads

Snapshots are cached briefly and are allowed to degrade conservatively when
Docker reads time out, sampling exceeds its shared budget, or cached data goes
stale.

`Capacity::RunAdmission` consumes those snapshots together with hard
host/user/project/create-PR ceilings. Auto mode may admit against Docker memory
budget when confidence is good, but degraded or missing snapshot paths fall
back conservatively, and sampling-budget exhaustion fails closed for that
admission pass.

## Accepted Divergence

RDR-005's host-side "one git worktree per agent run" model is superseded for
normal agent execution. Paid still keeps `Worktree` records and host-side
worktree flows for legacy metadata, conflict/maintenance paths, and explicit
bind-mount compatibility, but those legacy paths are not the current runtime
requirement for ordinary agent runs and should not be reintroduced as the
default design.

## Runner abstraction boundary (RDR-054)

`ExecutionRunners` defines the domain-oriented runner contract that will
replace direct Docker API access in orchestration code. The interface is driven
by what `Containers::Provision` actually does today, not speculative
generalization, and is reviewed against the coupling inventory (#3337) to
confirm coverage.

- `ExecutionRunners::Base` is the abstract interface: `provision`, `start`,
  `running?`, `reconnect`, `status`, `cancel`, `cleanup`, `.compatible?`, `.ping`. Method
  names and parameters never reference Docker concepts.
- A runner owns the complete execution environment (primary workload, sidecars,
  services, network, workspace) as a single lifecycle, plus the watchdog logic
  (startup, idle, wall-clock, heartbeat, abort-pattern detection).
- Value objects consolidate existing patterns: `RunSpec` (what to run),
  `RunnerHandle` (opaque, JSON-serializable reference for recovery),
  `ExecutionResult` (outcome, including OOM and timeout classification),
  `ExecutionStatus` (lifecycle status: `:running | :exited | :oom_killed |
  :not_found`, returned by `Base#status`), `NetworkingPolicy` (adapts
  `NetworkPolicy::NetworkContract`, drops the Docker network name; carries
  `mode`, `firewall?`, `allow_destinations`, and the RDR-055 `egress_profile`
  — `:locked` (default), `:research`, or `:open` — so orchestration can
  request a per-run egress posture without referencing Docker- or
  network-specific concepts),
  `ServiceDeclaration`, and `ComputeRequirements`.
- `ExecutionRunners::LocalDockerRunner` implements `Base` as a thin adapter over
  `Containers::Provision`: `#provision`/`#start`/`#running?`/`#reconnect`/`#status`/
  `#cancel`/`#cleanup` translate `RunSpec`/`RunnerHandle` to `Containers::Provision.new`,
  `#execute`, `#container_running?`, `#container_status`, `Containers::Provision.reconnect`,
  and `#cleanup` calls, and translate
  `Containers::Provision::Result` and its error classes into `ExecutionResult`
  and the `ExecutionRunners` error hierarchy. `RunnerHandle#metadata` carries
  the `agent_run_id`, `worktree_path`, and `environment` needed to reconnect a
  handle recovered after worker restart, since only the handle (not the
  original `RunSpec`) is passed back into later lifecycle calls.
  `Containers::Provision` itself is not modified, and services/sidecars are not
  yet translated (tracked separately). `ExecutionRunners.resolve` currently
  always returns `LocalDockerRunner`, since every existing backend (local
  Docker, remote Docker, Swarm) is a Docker transport.

### Persisted handle and recovery (RDR-054)

A `runner_handle` jsonb column on `agent_runs` (alongside, not replacing,
`container_id`/`container_host`) stores the serialized `RunnerHandle` so a
Temporal activity retry can recover after a worker restart or failover. When a
retry finds a persisted `runner_handle`, `AgentRun#provision_via_runner` routes
through `reuse_or_reconcile_via_runner`: it loads the handle via
`RunnerHandle.from_record`, checks `runner.running?`, and either reuses the
still-running environment or cleans up a dead/missing one before provisioning
fresh. A data migration backfills `runner_handle` from existing
`container_id` + `container_host` so legacy rows are immediately recoverable.
The column is also added to `container_pool_entries` and `service_containers`
so future pool and service-container code can store runner handles.

### Workspace strategy isolation (#3342)

Workspace storage is expressed as a provider-neutral `WorkspaceStrategy` on
`RunSpec`, isolating workspace assumptions from Docker volumes and bind mounts
so a future remote runner (Fly, Cloud Run) can substitute object storage or
ephemeral disk without changing orchestration code.

**This PR (implemented).** Volume and bind translation; volume-name isolation;
orphan-cleanup delegation.

- `WorkspaceStrategy` carries `mode` (`:named_volume | :bind_mount | :ephemeral
  | :object_storage`), the workload `mount_point`, an opaque `reference`
  (volume name, host path, or storage URI — nil until provisioned), the
  `writable_dirs` the workload needs (`WritableDir`: path, size, mode, exec),
  and a `heartbeat` `HeartbeatConfig`. The default writable directories
  (`/tmp`, `/home/agent/.cache`) and the heartbeat `mount_point` are declared
  on the strategy as the provider-neutral shape; runner-specific credential
  tmpfs mounts (e.g. `~/.claude`, `~/.codex`) remain a Docker-implementation
  detail owned by `Containers::Provision`.
- `LocalDockerRunner` translates the `:named_volume` and `:bind_mount` modes
  to Docker operations: `:named_volume` constructs the per-run volume name
  (`paid-workspace-<id>`) inside the runner via `workspace_volume_name_for`
  and mounts it via `Containers::Provision`; `:bind_mount` forwards the
  host-path reference as `Containers::Provision#worktree_path`. Volume-name
  construction lives in the runner, so no orchestration code or the domain
  model builds Docker volume names.
- `RunnerHandle#workspace_ref` stores the opaque workspace reference for
  recovery and cleanup across the provision → start → cleanup lifecycle.
- `AgentRun#cleanup_orphaned_workspace_volume` delegates volume-name
  construction and deletion to `LocalDockerRunner#cleanup_workspace_reference`
  rather than constructing `paid-workspace-<id>` in the model.

**Deferred (see CONTAINER-RUNTIME-012, -013, -014).** Writable tmpfs layout,
heartbeat ownership, pool workspace through the runner.

- `WorkspaceStrategy#writable_dirs` is declared on the strategy with a
  `WritableDir#docker_tmpfs_options` helper that produces the same option
  string Docker consumes, but `Containers::Provision#host_config` still
  hardcodes its own `Tmpfs` block; the runner does not yet translate the
  strategy's writable dirs into Provision calls (CONTAINER-RUNTIME-012).
- `WorkspaceStrategy#heartbeat` (`HeartbeatConfig`) declares the heartbeat
  mount point on the strategy, but `Containers::Provision#prepare_heartbeat_dir!`
  still owns the host temp-dir vs. in-container tmpfs selection from the
  backend's host-path capability, and callers still pass `heartbeat_path:` to
  `LocalDockerRunner#start` (CONTAINER-RUNTIME-013).
- Pool workspace management (`paid-pool-workspace-<pool_entry_id>`) still
  lives in `Containers::PoolManager` and `Containers::Provision`; the runner
  does not yet own pool workspace construction or cleanup (CONTAINER-RUNTIME-014).

`Containers::Provision` is intentionally unchanged in this PR: the existing
default workspace strategy (named volumes with in-container clone), host
bind-mount support, and all provision-side workspace/heartbeat tests are
preserved until the deferred specs land.

### Egress profile propagation (RDR-055, this PR)

`ExecutionRunners::NetworkingPolicy` now carries an `egress_profile` field so
orchestration can request a per-run egress posture through the runner contract
without ever naming Docker networks, iptables rules, or gateway
implementation details.

- `egress_profile` defaults to `:locked` for every factory method
  (`proxy_restricted`, `subscription_auth`, `direct_outbound`), so existing
  callers preserve the production default.
- `:research` propagates through the same `RunSpec` → `Containers::Provision`
  → `ExecutionInputManifest` chain; downstream tooling (research broker,
  gateway) reads the profile from the manifest's networking section without
  the runner exposing the firewall translation.
- `:open` (operator-only break-glass) is carried through the same path; a
  future enforcement adapter can reject the profile for production restricted
  runs by inspecting `policy.open?` / `policy.egress_profile`.
- The factory methods and `NetworkingPolicy#with` (Data-defined) keep the
  profile immutable and provider-neutral: `LocalDockerRunner` only reads
  `egress_profile` through the policy object, never reconstructs Docker-side
  state from it.

### Remote execution manifests (RDR-057)

`ExecutionRunners` now also defines the provider-neutral manifests that cross
the control-plane/runner boundary for remote execution. The manifest contract
is explicit value-object data, not ad hoc hashes.

- `ExecutionInputManifest` is derived from `RunSpec` and carries repository/ref,
  execution spec, prompt/context references, service declarations, and the four
  transfer lanes from RDR-057: Git, control-plane API, object storage, and
  credentials.
- `ExecutionOutputManifest` is derived from `ExecutionResult` + `AgentRun` and
  carries result summaries, log references, verification results, durable
  binary artifact references, and git output identity (`branch_name`,
  `result_commit_sha`, PR/review identity).
- Durable binary artifact references are object-storage-first records with a
  content type, storage locator (`key` and/or presigned `url`), and run
  context (`account_id`, `project_id`, `agent_run_id`) so the control plane
  never needs runner-local files after cleanup.
- Binary artifact references distinguish trusted source lanes from
  agent-authored ones, and both are namespace-scoped. Artifacts persisted by
  the runner under `AgentRun#external_metadata["artifact_manifest"]` (e.g. by
  `Screenshots::ContainerCapture`) are runner-written, but the field is not
  exclusively runner-written — interop ingestion
  (`Api::Projects::ExternalAgentRunsController` → `AgentRuns::IngestExternal`)
  persists caller-supplied `external_metadata` verbatim — so their storage
  keys are honored only when they live under the project's own storage
  namespace (`Screenshots::Storage.namespace_prefix`). Artifacts persisted by
  `AgentRuns::VerificationResultRecorder` from the agent-written result file
  inside the container are untrusted input: their locators are URL-only. In
  both lanes a `key` under another tenant's prefix would otherwise be
  re-signed into a working presigned URL by any durable consumer, since the
  manifest contract says durable consumers re-sign from the key. The run's
  `account_id`, `project_id`, and `agent_run_id` are always authoritative; an
  artifact-supplied context value cannot override the run's identity, so a
  run cannot misattribute its artifacts to a different tenant in the durable
  manifest.
- Presigned URLs are ephemeral — they expire within the SigV4 one-week cap —
  so artifact manifests persisted as durable records on the run (e.g.
  `AgentRun#external_metadata["artifact_manifest"]`) carry storage keys only;
  durable consumers re-sign from the key
  (`Screenshots::Storage#previous_artifacts` is the established pattern).
- The manifest shape is deliberately host-path-free. Workspace translation and
  container/worktree identifiers remain runner-local implementation details;
  the manifest only carries repo/ref and declarative workspace mode.
- Secrets are excluded by construction. Credential lanes carry only references
  (variable names, service names, config keys) and never secret values; service
  declarations expose `env_keys`, not `env` payloads.

## Provisioning-intent ledger and ownership tags (RDR-060)

Every execution resource a runner creates is reconcileable to its Paid origin
even when the runner process dies between provider creation and handle
persistence. RDR-060 wires runner provisioning into an execution-resource
ledger and a stable ownership-tag set.

- `ProvisioningIntent` is the ledger row. A runner records one in the `pending`
  state BEFORE it issues the provider create call, capturing the runner type,
  resource kind, environment, account, project, run, attempt, and the ownership
  tags. When the create succeeds the runner captures the provider resource
  identifier (status `created`); when the handle is built it links the
  serialized `RunnerHandle` (status `linked`). A runner that cannot identify a
  resource kind provisions without recording a ledger row.
- `ExecutionRunners::OwnershipTags` is the stable Paid ownership-tag set
  (environment, account, project, run, attempt, resource kind). The Docker
  runner translates it to `paid.*` Docker labels via the provisioner's
  `ownership_labels:` option so the live resource carries the same attribution
  as the ledger row.
- `ExecutionRunners::ProvisioningLedger` owns the ledger lifecycle (record,
  link-created, link-handle, mark-failed) so each runner's `#provision` stays
  thin. Recording is required before the create call; the post-create
  transitions are best-effort so a ledger UPDATE can never mask a successful
  handle return.
- Runner capabilities (`#resource_kind`, `#supports_tagging?`,
  `#supports_listing?`) are declared on `ExecutionRunners::Base` with
  conservative defaults (no resource kind, no tagging, no listing) so a future
  remote runner that cannot tag or list degrades explicitly: it still records
  the ledger row with `tagging_supported: false` and emits a warning instead of
  failing provisioning.
- The crash window is reconcileable by design: a ledger row left in the
  `created` state with a provider resource identifier, plus the ownership tags
  burned into the live resource, lets a reconciliation scan locate the orphan
  without the persisted `runner_handle`.

`LocalDockerRunner` populates ledger data while preserving its existing
cleanup behavior (firewall failure still cleans up the live container). The
ledger is append-only for the provision lifecycle; cleanup does not delete the
ledger row, so a full provision → cleanup history remains for auditing.

### Immutable agent image registry (RDR-059)

`AgentImage` is the system of record for what image actually runs in
production. The model records the immutable production identity
`(account_id, registry, repository, digest, architecture)` — the OCI
content-addressed tuple — alongside the logical profile name used by
`Containers::ImageResolver` (e.g. `base`, `elixir-node`, `ruby`), a mutable
`provenance` jsonb for build metadata, a mutable `metadata` jsonb for
operations/runbook links, the upstream `built_at` timestamp, and a lifecycle
`status` of `active`, `deprecated`, or `blocked`.

- Identity fields are immutable after creation. A new build produces a new
  digest, which is a new row. This is the only safe way to keep history
  accurate: editing an existing row would silently rewrite what the registry
  claims was running on a prior run.
- `status` is the only mutating lifecycle surface. The state machine allows
  `active -> deprecated -> blocked` and `active -> blocked`; transitions are
  idempotent so retrying an Avo action or job does not double-stamp
  timestamps or replace the recorded reason. Records are never deleted, so
  audit and rollback queries see the full history.
- The `schedulable?` predicate is the single gate for new placements. Today
  it is `active?`, but exposing the predicate means future states (e.g.
  `quarantined`) do not have to be repeated at every call site.
- Local development and single-backend deployments continue to use the
  literal `paid-agent:latest` constant in `Containers::ImageResolver`; the
  registry is the production source of truth, not a replacement for the
  resolver. The two layers compose: the resolver decides which logical
  profile a run needs, the registry records which content-addressed image
  the production host pulled, and a future `ImageResolver#resolve!` will
  cross-check the resolver output against the active registry rows.
- Uniqueness is enforced on `(account_id, registry, repository, digest,
  architecture)`. The same digest on a different architecture is a separate
  image record (multi-arch images register one row per architecture). The
  same identity may be recorded independently by different accounts. Digests
  are accepted in bare-hex or `sha256:`-prefixed form and stored
  canonicalized as `sha256:<hex>`, so the two input forms cannot register as
  two rows and the digest-pinned reference is always a valid OCI reference.
- Change history is tracked with logidze (`log_data`), following the
  `docker_hosts` precedent: lifecycle timestamps capture what and when, and
  logidze captures who edited the mutable `provenance`/`metadata` fields.
- A partial index over non-active rows keeps audit and rollback queries
  fast as the active set grows; a `(account_id, name, architecture)`
  index supports the (profile, architecture) scheduling decision.

### Provider-neutral networking intent (RDR-062)

`ExecutionRunners::NetworkingPolicy` now names six coarse egress intents
instead of leaking Docker network names across the runner boundary:
`:no_outbound`, `:proxy_only`, `:git_plus_proxy`, `:approved_services`,
`:model_direct`, and `:explicit_internet`.

- The three legacy constructors (`:proxy_restricted`, `:subscription_auth`,
  `:direct_outbound`) remain valid for compatibility, but
  `NetworkingPolicy#canonical_mode` normalizes them to the canonical intent
  names so runner-side translation paths only need to understand one
  vocabulary.
- `ExecutionRunners::Base.supports_policy?` is part of the runner contract.
  `LocalDockerRunner.compatible?` rejects specs whose networking intent the
  runner cannot implement before any provision-side effects occur.
- `LocalDockerRunner` remains the only place that translates intent into
  Docker implementation details. The four restricted intents use the
  restricted `paid_agent` network plus an allowlist firewall whose scope
  depends on the intent; the two unrestricted intents use the infrastructure
  network without a firewall.

### No-shared-filesystem conformance coverage (#3401)

RDR-057's no-shared-filesystem execution model is enforced by a
provider-neutral conformance suite that any runner implementation includes.
The suite (`spec/support/shared_examples/no_shared_filesystem_conformance.rb`)
drives the complete normal create-PR lifecycle — clone, run, log capture,
artifact output, result manifest, and cleanup — through the
`ExecutionRunners` contract only, deriving its `RunSpec` via
`RunSpec.from_agent_run` so every runner conforms to the same canonical,
host-path-free scenario:

- Code transport is the input manifest's Git lane; the workspace stays
  declarative (mode + mount point) with no host reference.
- Durable outputs travel on the object-storage lane (binary artifacts) and
  the control-plane API lane (log refs, verification), with git output
  identity on the Git lane.
- The persisted `RunnerHandle` and both manifests carry no host filesystem
  paths (`NoSharedFilesystemConformance.host_path_strings` walks the
  JSON-native payloads for absolute-path strings, allowing only the
  declarative in-container workspace mount point).
- The contract surface — interface methods, parameters, and value-object
  members — carries no Docker `exec` / bind-mount / shared-directory
  vocabulary.

A runner that requires shared host storage fails the suite: it either cannot
provision the host-path-free scenario or leaks host paths into its persisted
handle or manifests. Negative controls
(`spec/services/execution_runners/no_shared_filesystem_conformance_spec.rb`)
prove the checks reject host-storage-requiring runners, handles, manifests,
and contract surfaces, so the suite keeps its teeth against regressions.
`LocalDockerRunner` passes as the baseline without weakening local Docker
development: its platform is stubbed with the constraint that
`Containers::Provision` receives `worktree_path: nil` (the in-container
clone path), while legacy bind-mount runs remain a compatibility path
outside the conformance scenario.

### Execution resource ledger reconciliation (#3411)

Provision-time `runner_handle` persistence solves retry-time recovery for a
single workflow attempt, but it is not enough to keep cleanup durable across
provider drift, worker death, or reconciliation gaps. A separate
`execution_resources` ledger stores the provider-owned execution environments
Paid believes exist, plus cleanup state that survives job retries and workflow
restarts.

- Provisioning (runner and legacy Docker paths) upserts a single `environment`
  ledger row per `AgentRun`. The row records the provider identity
  (`runner_type`, `host`, `identifier`), the serialized `runner_handle` for
  handle-based fallback cleanup, and the opaque `workspace_ref`.
- Cleanup transitions the row from `active` to `cleanup_pending` before the
  provider call. If cleanup succeeds, the row becomes `cleaned`. If cleanup
  fails, the row remains `cleanup_pending` with durable failure metadata
  (`cleanup_attempts`, `next_cleanup_at`, `last_cleanup_error*`) so later
  reconciliation can retry with backoff even after the run record has cleared
  its direct container references.
- `ExecutionResourceReconciliationJob` groups ledger rows by runner/provider and
  asks the runner for a tagged resource listing when supported. That lets Paid
  compare “what the ledger says exists” against “what the provider still
  reports”, mark provider-missing rows cleaned (only when the owning agent run
  is finished or there is no owning run; a still-running run whose listing is
  missing is left active with `reduced_confidence` so a transient listing gap
  cannot sever the live link between the agent and its container), retry
  `cleanup_pending` resources that are still present, and adopt
  tagged-but-untracked orphan resources for missing or finished runs into the
  ledger before cleaning them up.
- Providers without tag/list support do not block migration. Reconciliation
  falls back to `runner_handle`-based cleanup for `cleanup_pending` rows and
  marks those passes `reduced_confidence`, because the system cannot prove the
  provider inventory matches the ledger and cannot adopt unknown orphans from a
  direct listing.
- Existing Docker janitors remain in place. `DockerOrphanCleanupJob` and
  `AgentRunResourceJanitorJob` still provide immediate cleanup during the
  migration, while the ledger reconciliation loop becomes the durable source of
  truth for retries and orphan adoption.

### Agent-image install failure diagnostics

The agent image carries contract-owned CLI install recipes from
`agent-harness`. When a build fails in a post-install assertion, the
Dockerfile must say which assertion failed and print the small amount of local
state needed to diagnose it, because the contract/package may be correct while
the image environment is wrong (for example PATH, launcher location, execute
bit, or runtime version drift).

The Oh My Pi install block is the concrete guardrail here: after installing Bun
and the `omp` package, the Dockerfile validates the `omp` launcher and the Bun
version with explicit failure messages instead of chained silent `test` calls.
That keeps cross-architecture failures actionable without requiring an operator
to rerun the whole image build under an interactive shell.

Because the generic Bun installer can pick an `amd64` binary that assumes AVX2,
the agent image installs the contract-pinned Bun release asset directly,
verifies it against Bun's published `SHASUMS256.txt`, and falls back to the
baseline `bun-linux-x64-baseline.zip` asset when `/proc/cpuinfo` does not
advertise AVX2. That keeps the Oh My Pi install path compatible with older
`amd64` runners instead of failing inside the post-install assertions.

## References

- `app/services/containers/provision.rb`
- `app/services/execution_runners.rb`
- `app/services/execution_runners/base.rb`
- `app/services/execution_runners/local_docker_runner.rb`
- `app/models/execution_resource.rb`
- `app/services/execution_resources/reconcile.rb`
- `app/jobs/execution_resource_reconciliation_job.rb`
- `app/services/execution_runners/provisioning_ledger.rb`
- `app/models/provisioning_intent.rb`
- `app/services/containers/resolve_host_for_run.rb`
- `app/services/containers/backend_scheduler.rb`
- `app/services/containers/service_provisioner.rb`
- `app/services/capacity/docker_snapshot.rb`
- `app/services/capacity/run_admission.rb`
- `app/models/agent_run.rb`
- `app/models/agent_image.rb`
- `db/migrate/20260817195654_create_agent_images.rb`
- `spec/services/containers/provision_spec.rb`
- `spec/models/agent_image_spec.rb`
- `spec/services/execution_runners_spec.rb`
- `spec/services/execution_runners/base_spec.rb`
- `spec/services/execution_runners/local_docker_runner_spec.rb`
- `spec/models/provisioning_intent_spec.rb`
- `spec/services/execution_runners/no_shared_filesystem_conformance_spec.rb`
- `spec/support/no_shared_filesystem_conformance.rb`
- `spec/support/shared_examples/execution_runner_contract.rb`
- `spec/support/shared_examples/no_shared_filesystem_conformance.rb`
- `spec/services/containers/service_provisioner_spec.rb`
- `spec/services/capacity/docker_snapshot_spec.rb`
- `spec/services/capacity/run_admission_spec.rb`
- `spec/services/containers/backend_scheduler_spec.rb`
- `spec/requests/agent_runs_spec.rb`
- `spec/jobs/process_run_queue_job_spec.rb`
