# RDR-061 Audit Report — 2026-08-21 Closeout

- **RDR**: [RDR-061: Infrastructure Safety Rails and Execution Audit Events](RDR-061-infrastructure-safety-and-audit.md)
- **Audit date**: 2026-08-21
- **Umbrella issue**: [#3421](https://github.com/viamin/paid/issues/3421) (remains open pending the remaining RDR-061 gaps)
- **Follow-up issues**:
  - [#3553](https://github.com/viamin/paid/issues/3553) — instrument execution lifecycle audit events across provisioning and cleanup
  - [#3554](https://github.com/viamin/paid/issues/3554) — enforce infrastructure spend thresholds before provisioning
- **Conclusion**: Partially Implemented. The core pre-provisioning safety rails for aggregate requested CPU/memory/disk, per-execution resource maxima, provisioning-rate limits, and execution-disable controls are shipped. The dedicated `ExecutionAuditEvent` model is also shipped as an append-only, secret-safe record. However, the execution lifecycle still does not emit the RDR-061 audit event classes, and no Paid-owned infrastructure spend-threshold enforcement is wired into the pre-provisioning safety path yet.

## Validation Evidence

Executed during the 2026-08-21 closeout audit recorded against umbrella issue
[#3421](https://github.com/viamin/paid/issues/3421).

```console
$ bundle exec rails db:prepare
Created database 'agent_run_31169_attempt_0'

$ bundle exec rspec \
    spec/services/capacity/run_admission_spec.rb \
    spec/models/execution_control_spec.rb \
    spec/models/execution_audit_event_spec.rb \
    spec/services/config/production_validator_spec.rb
110 examples, 0 failures
```

Additional full-repo verification executed after the documentation updates:

```console
$ bin/coherence-check.mjs
Repo-wide pre-existing LID drift/orphan report; no RDR-061-specific failures

$ bundle exec rubocop
3040 files inspected, no offenses detected

$ bundle exec rspec
19903 examples, 0 failures, 3 pending
```

## Acceptance Criteria vs. Shipped Implementation

### Criterion 1: Aggregate CPU/memory/disk and provisioning-rate safety rails are enforced before provisioning

**Status**: Implemented.

**Shipped**:

- `Capacity::RunAdmission#call` decorates every admission decision with
  requested-resource and provisioning-window state before applying the
  infrastructure safety rails, so denials happen before provisioning starts:
  `app/services/capacity/run_admission.rb:29-42`,
  `app/services/capacity/run_admission.rb:222-316`.
- The shipped denial set covers:
  - per-execution CPU/memory/disk ceilings:
    `app/services/capacity/run_admission.rb:275-280`
  - aggregate global/host requested CPU/memory/disk ceilings:
    `app/services/capacity/run_admission.rb:283-299`
  - global/account/project provisioning-rate ceilings with next-eligible
    timestamps: `app/services/capacity/run_admission.rb:301-315`
- Production boot now fails closed when the required infrastructure limit
  environment variables are missing or non-positive:
  `app/services/capacity/infrastructure_limits.rb:5-63`,
  `app/services/config/production_validator.rb:80-95`,
  `app/services/config/production_validator.rb:168-175`.

**Evidence**:

- `app/services/capacity/run_admission.rb:29-42`
- `app/services/capacity/run_admission.rb:222-316`
- `app/services/capacity/infrastructure_limits.rb:5-63`
- `app/services/config/production_validator.rb:80-95`
- `app/services/config/production_validator.rb:168-175`

**Tests**:

- `spec/services/capacity/run_admission_spec.rb`
- `spec/services/config/production_validator_spec.rb`

**Verdict**: Implemented.

---

### Criterion 2: Emergency execution disable works globally, per account/project, and per runner/backend

**Status**: Implemented.

**Shipped**:

- `ExecutionControl` scope resolution and active-run impact are implemented for
  global, account, project, runner, and backend scopes.
- Emergency mode cancels active scoped runs and enqueues cleanup via
  `AgentRunCancellationJob`; capacity mode parks runs and enqueues
  `ExecutionControlParkCleanupJob` when workflow/container teardown is needed:
  `app/services/execution_controls/run_impact.rb:13-23`,
  `app/services/execution_controls/run_impact.rb:25-97`.
- Queue-time enforcement for global/account/project controls and active-run
  impact auditing is covered by the execution-disable intent docs and shipped
  tests referenced there.

**Evidence**:

- `app/services/execution_controls/run_impact.rb:13-23`
- `app/services/execution_controls/run_impact.rb:25-97`
- `app/services/execution_controls/run_impact.rb:148-245`
- `docs/intent/execution-disable-controls/execution-disable-controls-specs.md`

**Tests**:

- `spec/models/execution_control_spec.rb`
- `spec/jobs/process_run_queue_job_spec.rb`
- `spec/services/runners/preflight_check_spec.rb`
- `spec/services/containers/backend_scheduler_spec.rb`

**Verdict**: Implemented.

---

### Criterion 3: Infrastructure spend thresholds are enforced after infra cost accounting lands

**Status**: Gap.

**Shipped**:

- No spend-threshold check exists in `Capacity::RunAdmission`'s
  `infrastructure_denial` chain; the current chain ends at execution-resource,
  aggregate-requested-resource, and provisioning-rate denials only:
  `app/services/capacity/run_admission.rb:269-315`.
- `Capacity::InfrastructureLimits` and `Config::ProductionValidator` require
  resource/provisioning env vars only; there are no production-required spend
  threshold settings there yet:
  `app/services/capacity/infrastructure_limits.rb:5-63`,
  `app/services/config/production_validator.rb:80-95`.

**What is missing**:

- Paid-owned infrastructure spend-threshold checks on the pre-provisioning
  safety path.
- Explicit denial reasons and tests for spend-threshold breaches.

**Evidence**:

- `app/services/capacity/run_admission.rb:269-315`
- `app/services/capacity/infrastructure_limits.rb:5-63`
- `app/services/config/production_validator.rb:80-95`

**Follow-up**:

- [#3554](https://github.com/viamin/paid/issues/3554)

**Verdict**: Gap.

---

### Criterion 4: Execution audit events answer the investigation questions without storing secret values

**Status**: Partial.

**Shipped**:

- `ExecutionAuditEvent` is an append-only, tenant-consistent, secret-safe model
  with scopes for account/project/run/runner/image/resource/correlation lookup:
  `app/models/execution_audit_event.rb:16-87`.
- Secret-shaped metadata and string attributes are rejected before persistence:
  `app/models/execution_audit_event.rb:44-69`,
  `app/models/execution_audit_event.rb:103-150`.

**What is missing**:

- No production execution lifecycle call sites currently write the RDR-061
  event classes. The execution-audit LLD still documents call-site
  instrumentation as follow-up work:
  `docs/intent/execution-audit/execution-audit-design.md`.
- Code search during this closeout found `ExecutionAuditEvent.record!` only in
  the model test, not in provisioning, cleanup, runner selection, or network
  policy call paths.

**Evidence**:

- `app/models/execution_audit_event.rb:16-87`
- `app/models/execution_audit_event.rb:103-150`
- `docs/intent/execution-audit/execution-audit-design.md`

**Tests**:

- `spec/models/execution_audit_event_spec.rb`
- `spec/jobs/execution_audit_event_retention_job_spec.rb`

**Follow-up**:

- [#3553](https://github.com/viamin/paid/issues/3553)

**Verdict**: Partial — the record type is shipped, but the investigation event stream is not.

---

### Criterion 5: Audit events link to runner, image, credential class, network policy, and resource ledger data where available

**Status**: Partial.

**Shipped**:

- The model supports all of the required fields:
  `runner_key`, `backend`, `image_reference`, `image_digest`,
  `credential_classes`, `network_policy`, `resource_type`, `resource_id`, and
  `correlation_id`: `app/models/execution_audit_event.rb:21-30`,
  `app/models/execution_audit_event.rb:51-79`.

**What is missing**:

- Because execution lifecycle events are not emitted yet, these fields are not
  populated by the actual provisioning/cleanup path.
- Resource-ledger linkage remains limited by RDR-060's partial implementation,
  so even after instrumentation some resource identifiers will remain
  best-effort until the ledger work completes.

**Evidence**:

- `app/models/execution_audit_event.rb:21-30`
- `app/models/execution_audit_event.rb:51-79`
- `docs/rdrs/RDR-060-external-execution-resource-ledger.md`

**Follow-up**:

- [#3553](https://github.com/viamin/paid/issues/3553)

**Verdict**: Partial — the schema supports the linkage, but the emitted event stream does not yet provide it.

---

### Criterion 6: Provider-level quotas and budgets are documented as backstops, not the primary Paid behavior

**Status**: Implemented.

**Shipped**:

- RDR-061 explicitly documents provider quotas, billing alerts, budget
  notifications, IAM guardrails, and maximum task/machine sizes as
  defense-in-depth backstops rather than primary product behavior:
  `docs/rdrs/RDR-061-infrastructure-safety-and-audit.md:64-68`.
- The same document states that Paid safety rails must fail closed before
  provider provisioning and that provider quotas fail too late to be the main
  product model:
  `docs/rdrs/RDR-061-infrastructure-safety-and-audit.md:33-44`,
  `docs/rdrs/RDR-061-infrastructure-safety-and-audit.md:135-145`.

**Evidence**:

- `docs/rdrs/RDR-061-infrastructure-safety-and-audit.md:33-44`
- `docs/rdrs/RDR-061-infrastructure-safety-and-audit.md:64-68`
- `docs/rdrs/RDR-061-infrastructure-safety-and-audit.md:135-145`

**Verdict**: Implemented.

## Conclusion

RDR-061 should move from **Draft** to **Partially Implemented** as of
2026-08-21.

What shipped:

- pre-provisioning aggregate resource ceilings
- pre-provisioning provisioning-rate ceilings
- per-execution resource maxima
- global/account/project/runner/backend execution-disable controls
- append-only, secret-safe `ExecutionAuditEvent` storage and retention

What remains open:

- lifecycle execution audit-event emission ([#3553](https://github.com/viamin/paid/issues/3553))
- pre-provisioning infrastructure spend-threshold enforcement ([#3554](https://github.com/viamin/paid/issues/3554))

The umbrella closeout issue [#3421](https://github.com/viamin/paid/issues/3421)
should remain open until those gaps land and the closeout can be rerun.
