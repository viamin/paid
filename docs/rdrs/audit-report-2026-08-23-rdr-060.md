# RDR-060 Audit Report — 2026-08-23 Closeout

- **RDR**: [RDR-060: External Execution Resource Ledger](RDR-060-external-execution-resource-ledger.md)
- **Audit date**: 2026-08-23
- **Umbrella issue**: [#3600](https://github.com/viamin/paid/issues/3600) (remains open pending the remaining RDR-060 gaps)
- **Follows**: the [RDR Closeout Checklist](closeout-checklist.md)
- **Conclusion**: Partially Implemented (unchanged verdict; scope shifted).
  Since the [2026-08-18 closeout](audit-report-2026-08-18-rdr-060.md),
  [#3409](https://github.com/viamin/paid/issues/3409) (ledger data model) and
  [#3410](https://github.com/viamin/paid/issues/3410) (runner/ledger
  integration) both shipped and closed, upgrading three of the six
  acceptance criteria from Gap to Partial. Three blocking dependencies remain
  open: [#3411](https://github.com/viamin/paid/issues/3411) (reconciliation),
  [#3352](https://github.com/viamin/paid/issues/3352) (idempotent lifecycle),
  [#3358](https://github.com/viamin/paid/issues/3358) (runner conformance
  suite) — see [Blocking Dependencies Reconciliation](#blocking-dependencies-reconciliation).

## Validation Evidence

Executed during the 2026-08-23 closeout audit recorded against umbrella issue
[#3600](https://github.com/viamin/paid/issues/3600). All suites passed in
full; no failures. Four pending examples are pre-existing, intentional
shared-example skips for runner types that do not declare a `resource_kind`
(so the ledger does not apply to them), not regressions.

```console
$ bundle exec rspec spec/models/execution_resource_ledger_entry_spec.rb \
    spec/models/provisioning_intent_spec.rb
63 examples, 0 failures

$ bundle exec rspec spec/services/execution_runners_spec.rb \
    spec/services/execution_runners/
297 examples, 0 failures, 4 pending

$ bundle exec rspec spec/jobs/agent_run_resource_janitor_job_spec.rb \
    spec/models/worktree_spec.rb spec/models/docker_host_spec.rb
51 examples, 0 failures

$ bundle exec rspec spec/services/containers/mcp_provisioner_spec.rb \
    spec/services/containers/service_provisioner_spec.rb
92 examples, 0 failures
```

## Acceptance Criteria vs. Shipped Implementation

### Criterion 1: Externally provisioned execution resources can be represented in the ledger

**Status**: Partial (unchanged verdict; evidence shifted).

**Shipped since 2026-08-18**:

- `ExecutionResourceLedgerEntry` (#3409, closed) — a durable
  `execution_resource_ledger_entries` table and model covering all seven
  resource kinds in scope (`primary_environment`, `service`, `sidecar`,
  `workspace`, `network`, `preview_tunnel`, `temporary_storage`), a 6-state
  lifecycle (`provisioning`, `active`, `cleanup_pending`, `deleted`,
  `orphaned`, `cleanup_failed`) with enforced transitions, tenant scoping via
  RLS, and secret-safe `tags`/`runner_handle` validation. Fully specified as
  `RESOURCE-LEDGER-001` through `RESOURCE-LEDGER-004` and
  `RESOURCE-LEDGER-007` in
  `docs/intent/execution-resource-ledger/execution-resource-ledger-specs.md`
  (all `[x]`).
- `ProvisioningIntent` (#3410, closed) — a separate, narrower table recording
  a crash-window intent (`pending` -> `created` -> `linked`/`failed`) for the
  primary agent container, written by
  `ExecutionRunners::ProvisioningLedger#record_intent` from
  `LocalDockerRunner#provision` (`app/services/execution_runners/local_docker_runner.rb:82-99`).

**What is still missing**:

- `ExecutionResourceLedgerEntry` itself has no write path. A repo-wide search
  (`grep -rn "ExecutionResourceLedgerEntry" app/`) finds it referenced only
  in its own model file and in a comment in
  `app/services/execution_audit_events/lifecycle.rb:113-119` explicitly
  documenting the gap: *"the runtime provision/cleanup path does not create
  or update them yet (RESOURCE-LEDGER-005, tracked by #3352/#3410)."* This is
  spec `RESOURCE-LEDGER-005`, still unchecked.
- `ProvisioningIntent` — the table that *is* written — only covers the
  primary agent container via `LocalDockerRunner`. MCP sidecar containers
  (`app/services/containers/mcp_provisioner.rb`) and shared service
  containers (`app/services/containers/service_provisioner.rb`) have no
  intent record and no ledger row; they remain tracked only via
  `AgentRun#mcp_sidecar_container_ids` / `ServiceContainer#docker_container_id`.
- `ContainerPoolEntry` has no ledger or intent association
  (`grep -n "execution_resource_ledger\|ProvisioningIntent" app/models/container_pool_entry.rb`
  returns nothing).

**Evidence**:

- `app/models/execution_resource_ledger_entry.rb:35-225` — model, resource
  kinds, lifecycle state machine
- `app/models/provisioning_intent.rb` — crash-window intent model, including
  `reconcileable`/`orphans` query scopes (see Criterion 4)
- `app/services/execution_runners/provisioning_ledger.rb:65-91` —
  `record_intent` writes `ProvisioningIntent`, not `ExecutionResourceLedgerEntry`
- `app/services/execution_audit_events/lifecycle.rb:113-126` — explicit
  in-code documentation of the `ExecutionResourceLedgerEntry` write-path gap
- `app/services/containers/mcp_provisioner.rb`, `app/services/containers/service_provisioner.rb` —
  no ledger/intent integration
- `docs/intent/execution-resource-ledger/execution-resource-ledger-specs.md:62-66` —
  `RESOURCE-LEDGER-005` (unchecked)

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/models/execution_resource_ledger_entry_spec.rb` — 48 examples,
  lifecycle/tenant/secret-safety validation
- `spec/models/provisioning_intent_spec.rb` — 15 examples, including
  `reconcileable`/`orphans` scope coverage
- `spec/services/containers/mcp_provisioner_spec.rb`,
  `spec/services/containers/service_provisioner_spec.rb` — 92 examples,
  confirm current (ledger-free) sidecar/service provisioning behavior

**Verdict**: Partial — the unified ledger's data model shipped, but the
system still writes to a second, narrower table for only one of several
resource-provisioning paths.

---

### Criterion 2: Provider resources carry stable Paid ownership tags

**Status**: Partial (unchanged verdict; evidence shifted).

**Shipped since 2026-08-18**:

- `ExecutionRunners::OwnershipTags` (`app/services/execution_runners.rb:668-707`)
  is a `Data.define` that builds a `paid.*`-prefixed label map
  (`paid.environment`, `paid.account`, `paid.project`, `paid.run`,
  `paid.attempt`, `paid.resource`) from an agent run and resource kind.
  `LocalDockerRunner#provision` fetches these via
  `ledger.ownership_labels_for` and passes them into
  `Containers::Provision` as `ownership_labels:`
  (`app/services/execution_runners/local_docker_runner.rb:83-91`), which
  merges them into both the container's `container_labels` and the workspace
  volume's `volume_options` (`app/services/containers/provision.rb:2600-2632`).

**What is still missing**:

- `paid.created_at` is not part of `OwnershipTags` at all.
- `paid.managed` is applied only to the workspace volume
  (`volume_options` hardcodes `"paid.managed" => "true"` at
  `provision.rb:2602`) — the primary container's own `container_labels`
  method does not set it, so the container itself is not tagged
  `paid.managed`.
- MCP sidecar containers (`McpProvisioner#create_sidecar_container`,
  `app/services/containers/mcp_provisioner.rb:224-225`) and service
  containers (`ServiceProvisioner#create_docker_container`,
  `app/services/containers/service_provisioner.rb:540-541`) still apply only
  their narrow, provisioner-specific label pair
  (`paid.mcp_sidecar`/`paid.agent_run_id` and
  `paid.service_container`/`paid.service_container_id` respectively), with
  no `OwnershipTags` integration and none of `paid.managed`,
  `paid.account_id`, `paid.created_at`, or `paid.resource_kind`.

**Evidence**:

- `app/services/execution_runners.rb:668-707` — `OwnershipTags` definition
  and `to_label_map`
- `app/services/execution_runners.rb:23` —
  `REQUIRED_OWNERSHIP_TAG_NAMES = %w[environment account project run attempt resource]`
  (six tags; no `managed` or `created_at`)
- `app/services/execution_runners/local_docker_runner.rb:83-91` — ownership
  labels wired into `Containers::Provision`
- `app/services/containers/provision.rb:2600-2632` — `volume_options`
  (hardcodes `paid.managed`) and `container_labels` (does not)
- `app/services/containers/mcp_provisioner.rb:224-225`,
  `app/services/containers/service_provisioner.rb:540-541` — narrow,
  non-conformant label pairs

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/services/execution_runners/local_docker_runner_spec.rb` (part of the
  124-example `LocalDockerRunner` suite) — ownership label application

**Verdict**: Partial — the primary container/volume path now applies a
consistent ownership-tag set via a shared `OwnershipTags` value object
(an improvement over the previous ad hoc labeling), but the tag set is still
short two RDR-mandated tags and MCP sidecar/service containers remain
entirely outside it.

---

### Criterion 3: Crash-window provisioning intents exist before provider create calls

**Status**: Partial (upgraded from Gap).

**Shipped since 2026-08-18**:

- `ExecutionRunners::ProvisioningLedger#record_intent`
  (`app/services/execution_runners/provisioning_ledger.rb:65-91`) is called
  from `LocalDockerRunner#provision`
  (`app/services/execution_runners/local_docker_runner.rb:82-84`) **before**
  `Containers::Provision#provision` issues the Docker create call. The
  intent row is `pending` at that point; `link_created` captures the
  provider resource ID immediately after creation
  (`local_docker_runner.rb:96-99`, comment: *"Capture the provider resource
  identifier immediately so a crash between here and handle persistence
  still leaves a reconcileable ledger row (CONTAINER-RUNTIME-027)"*), and
  `link_handle` advances the row to `linked` once the runner handle is
  built. `record_intent` raises on persistence failure so the runner never
  proceeds to create a resource it cannot reconcile; `link_created`/
  `link_handle`/`mark_failed` are deliberately best-effort so a ledger
  update failure can never mask a successful provision.

**What is still missing**:

- MCP sidecar provisioning (`McpProvisioner#create_sidecar_container`) and
  service-container provisioning
  (`ServiceProvisioner#create_docker_container`) call the Docker create API
  directly with no pre-create intent record, so their crash window is still
  open.

**Evidence**:

- `app/services/execution_runners/provisioning_ledger.rb:65-91` —
  `record_intent`
- `app/services/execution_runners/local_docker_runner.rb:69-103` — intent
  recorded before `service.provision`, linked after
- `app/services/containers/mcp_provisioner.rb`,
  `app/services/containers/service_provisioner.rb` — no intent recording

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/services/execution_runners/local_docker_runner_spec.rb` — intent
  recorded pending before create, linked after; concurrent-retry and
  crash-window scenarios covered (124 examples in the runner suite)
- `spec/models/provisioning_intent_spec.rb:74` — `.orphans` scope returns
  created intents that carry a provider resource id but no linked handle
  (the crash-window signal)

**Verdict**: Partial — the primary container path now has real crash-window
protection; MCP sidecar and service-container provisioning do not.

---

### Criterion 4: Reconciliation can detect ledger/provider drift and retry cleanup

**Status**: Gap (unchanged).

**Shipped since 2026-08-18**:

- `ProvisioningIntent` ships two query scopes intended for a future
  reconciliation process: `.reconcileable` (pending/created intents not yet
  linked or failed) and `.orphans` (created intents with a provider resource
  ID but no linked handle) — `app/models/provisioning_intent.rb:35-36`. These
  are query primitives, not a running process.

**What is still missing**:

- No job or service calls `.reconcileable`/`.orphans` on a schedule, or
  compares any ledger table against live provider (Docker) state.
  `app/jobs/service_container_reconciliation_job.rb` reconciles
  `ServiceContainer` records against the Docker daemon directly and is
  unrelated to the RDR-060 ledger.
- `RESOURCE-LEDGER-006` (*"A reconciliation process SHALL periodically
  compare ledger rows against live provider state..."*) remains unchecked in
  `docs/intent/execution-resource-ledger/execution-resource-ledger-specs.md:68-71`.
- The janitor job (`AgentRunResourceJanitorJob`) still only retries cleanup
  for resources it already has a record of; it does not discover orphans
  with no application-side record.

**Evidence**:

- `app/models/provisioning_intent.rb:35-36` — `reconcileable`/`orphans`
  scopes exist but are unused outside specs
  (`grep -rn "\.reconcileable\|\.orphans" app/` returns only the model)
  and are unused outside specs (`grep -rln "reconcil" app/ -i` finds no
  RDR-060 reconciliation job)
- `app/jobs/service_container_reconciliation_job.rb` — unrelated
  reconciliation (Docker daemon vs. `ServiceContainer`, not the ledger)
- `docs/intent/execution-resource-ledger/execution-resource-ledger-specs.md:68-71` —
  `RESOURCE-LEDGER-006` (unchecked)

**Verdict**: Gap — the data model now exposes the query surface a
reconciliation job would need, but #3411 (which owns building that job) is
still open.

---

### Criterion 5: Providers without tag/list support degrade explicitly and safely

**Status**: Partial (upgraded from Gap).

**Shipped since 2026-08-18**:

- `ExecutionRunners::ProvisioningLedger` takes `supports_tagging:` and
  `supports_listing:` at construction and, when either is false, records
  explicit `tagging_degraded`/`listing_degraded` metadata on the
  `ProvisioningIntent` row (`degradation_metadata`,
  `app/services/execution_runners/provisioning_ledger.rb:151-157`) and logs
  a `warn`-level, structured message identifying the gap
  (`warn_capability_degradations`, `provisioning_ledger.rb:166-183`) —
  satisfying the "no silent omission" requirement from the RDR's Decision
  section.

**What is still missing**:

- This degradation path is only exercised by `LocalDockerRunner`, which
  unconditionally declares `supports_tagging? == true` and
  `supports_listing? == true`
  (`app/services/execution_runners/local_docker_runner.rb:57-63`). No other
  runner or backend in the codebase currently constructs a
  `ProvisioningLedger` with either capability set to `false` in production
  code, so the degradation path is proven correct in tests but not yet
  triggered by any real runner.

**Evidence**:

- `app/services/execution_runners/provisioning_ledger.rb:151-193` —
  degradation metadata and warning logs
- `app/services/execution_runners/local_docker_runner.rb:57-63` —
  `supports_tagging?`/`supports_listing?` both hardcoded `true`

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/services/execution_runners/local_docker_runner_spec.rb:919-995` —
  `"degradation when tagging is unsupported (RDR-060)"` and
  `"degradation when listing is unsupported (RDR-060)"` describe blocks:
  assert `metadata` includes `"tagging_degraded" => true` /
  `"listing_degraded" => true` and that a `Rails.logger.warn` with
  `message: "execution_runners.tagging_unsupported_degraded"` /
  `"execution_runners.listing_unsupported_degraded"` is emitted

**Verdict**: Partial — the degradation mechanism is implemented and tested,
but no shipped runner currently exercises the degraded path, so it has not
yet been proven against a real non-tagging/non-listing provider.

---

### Criterion 6: Existing Docker janitors still work during migration

**Status**: Implemented (unchanged).

**Shipped**:

`AgentRunResourceJanitorJob`, `CleanupContainerActivity`,
`CleanupWorktreeActivity`, and `EnqueueJanitorActivity` are unmodified by the
#3409/#3410 work and continue to pass in full.

**Evidence**:

- `app/jobs/agent_run_resource_janitor_job.rb` — full cleanup implementation
- `app/temporal/activities/cleanup_container_activity.rb`,
  `cleanup_worktree_activity.rb`, `enqueue_janitor_activity.rb`

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/jobs/agent_run_resource_janitor_job_spec.rb` — 12 examples

**Verdict**: Satisfied.

---

## Gaps

Each gap below is already owned by an open dependency issue; no new child
issues are filed by this audit.

1. **`ExecutionResourceLedgerEntry` has no write path** — tracked by
   `RESOURCE-LEDGER-005`, referenced against #3352/#3410 in code comments.
   #3410 is now closed but shipped `ProvisioningIntent` integration instead
   of wiring the unified ledger table; #3352 (idempotent lifecycle) remains
   open and is the more likely place this lands. See Criterion 1.
2. **MCP sidecar and service containers have no ledger/intent coverage** —
   no single tracked issue names this explicitly; it is in scope for
   whichever of #3352/#3411/#3358 extends ledger coverage beyond the primary
   container. Flagged here so it is not lost. See Criteria 1-3.
3. **Ownership tag set incomplete (`paid.created_at` missing; `paid.managed`
   container-only-via-volume)** — tracked in #3352 per the RDR's phase plan.
   See Criterion 2.
4. **No reconciliation process** — tracked in
   [#3411](https://github.com/viamin/paid/issues/3411). See Criterion 4.
5. **Degradation path unproven against a real degraded provider** — tracked
   in [#3358](https://github.com/viamin/paid/issues/3358) (runner
   conformance suite is the natural place to add a non-tagging/non-listing
   conformance case). See Criterion 5.
6. **Idempotent lifecycle and crash recovery using ledger state** — tracked
   in [#3352](https://github.com/viamin/paid/issues/3352).
7. **Runner conformance suite** — tracked in
   [#3358](https://github.com/viamin/paid/issues/3358).

## Child Issues

None filed by this audit. The existing blocking dependencies on
[#3600](https://github.com/viamin/paid/issues/3600) already cover every gap
identified above:

- [#3411](https://github.com/viamin/paid/issues/3411) — Reconcile execution
  resource ledger against provider state. **Open**. See gaps 2, 4 above.
- [#3352](https://github.com/viamin/paid/issues/3352) — Idempotent execution
  lifecycle and crash recovery for external resources. **Open**. See gaps 1,
  2, 3, 6 above.
- [#3358](https://github.com/viamin/paid/issues/3358) — Runner conformance
  suite and provider comparison benchmark methodology. **Open**. See gaps 2,
  5, 7 above.
- [#3409](https://github.com/viamin/paid/issues/3409) — Add execution
  resource ledger data model. **Closed**. Shipped evidence for Criterion 1.
- [#3410](https://github.com/viamin/paid/issues/3410) — Integrate runners
  with ledger intents and provider tags. **Closed**. Shipped evidence for
  Criteria 2, 3, 5.

## Blocking Dependencies Reconciliation

Issue [#3600](https://github.com/viamin/paid/issues/3600) lists three
blocking dependencies. This section reconciles each against the 2026-08-23
audit.

| Dependency | State | Reconciliation |
|------------|-------|----------------|
| [#3411](https://github.com/viamin/paid/issues/3411) — reconciliation against provider state | Open | Remaining RDR-060 scope (gap 4). `ProvisioningIntent.reconcileable`/`.orphans` scopes now exist as query primitives, but no job or service invokes them, and `ExecutionResourceLedgerEntry` still has no write path to reconcile against. |
| [#3352](https://github.com/viamin/paid/issues/3352) — idempotent execution lifecycle and crash recovery | Open | Remaining RDR-060 scope (gaps 1, 2, 3, 6). Owns wiring `ExecutionResourceLedgerEntry` itself into the provision/cleanup path (`RESOURCE-LEDGER-005`), extending ledger/intent coverage to MCP sidecar and service containers, and completing the ownership tag set. |
| [#3358](https://github.com/viamin/paid/issues/3358) — runner conformance suite | Open | Remaining RDR-060 scope (gaps 2, 5, 7). No conformance suite yet validates ledger integration across runners or exercises the tag/list degradation path against a real non-conformant provider. |

Because all three blocking dependencies are open and each represents
remaining RDR-060 scope, the "Partially Implemented" verdict is
load-bearing: #3409 and #3410 closed the *ledger data model* and *primary
container crash-window/tagging* layers, but the *unified ledger write path*,
*full resource-type coverage*, *active reconciliation*, and *conformance
testing* are not complete. This audit recommends keeping
[#3600](https://github.com/viamin/paid/issues/3600) open and re-running the
closeout after #3411, #3352, and #3358 land.
