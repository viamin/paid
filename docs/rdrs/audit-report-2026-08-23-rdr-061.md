# RDR-061 Audit Report — 2026-08-23 Final Closeout

- **RDR**: [RDR-061: Infrastructure Safety Rails and Execution Audit Events](RDR-061-infrastructure-safety-and-audit.md)
- **Audit date**: 2026-08-23
- **Closeout issue**: [#3601](https://github.com/viamin/paid/issues/3601) (final closeout after audit and spend-threshold gaps land)
- **Prior closeout**: [#3421](https://github.com/viamin/paid/issues/3421), partial, see [`audit-report-2026-08-21-rdr-061.md`](audit-report-2026-08-21-rdr-061.md)
- **Dependencies verified**: [#3553](https://github.com/viamin/paid/issues/3553) (lifecycle audit-event instrumentation) and [#3554](https://github.com/viamin/paid/issues/3554) (infrastructure spend-threshold enforcement)
- **Conclusion**: Implemented. Both gaps identified in the 2026-08-21 closeout have shipped code and passing test evidence. No RDR-061 acceptance criteria remain open.

## Validation Evidence

```console
$ bundle exec rspec \
    spec/services/capacity/run_admission_spec.rb \
    spec/models/execution_control_spec.rb \
    spec/models/execution_audit_event_spec.rb \
    spec/services/config/production_validator_spec.rb \
    spec/services/capacity/infrastructure_spend_spec.rb \
    spec/services/capacity/infrastructure_spend_guard_spec.rb \
    spec/services/containers/provision_spec.rb \
    spec/jobs/execution_audit_event_retention_job_spec.rb \
    spec/temporal/activities/create_agent_run_activity_spec.rb \
    spec/jobs/process_run_queue_job_spec.rb \
    spec/services/agent_runs/bind_runner_spec.rb \
    spec/models/agent_run_spec.rb
1277 examples, 0 failures

$ node bin/coherence-check.mjs
Repo-wide pre-existing LID drift/orphan report; no RDR-061-specific findings
(all EXECUTION-AUDIT-* and INFRA-SPEND-* specs marked [x], zero uncovered
gap markers in docs/intent/execution-audit/ or
docs/intent/infrastructure-spend-thresholds/)
```

## Re-Verification of the Two Open Gaps from the 2026-08-21 Closeout

### Gap 1 (was Criterion 4/5): Lifecycle execution audit-event emission — #3553

**Status**: Implemented.

**Shipped**:

- `ExecutionAuditEvents::Lifecycle` (`app/services/execution_audit_events/lifecycle.rb`)
  centralizes construction of `ExecutionAuditEvent` records, resolving
  project/account from the run, normalizing network policy, and mapping
  credential-delivery modes to the RDR's credential-class vocabulary.
- Call sites now emit the full event-class set named in the RDR's Audit Event
  Model:
  - `execution.runner_selected` — `app/services/agent_runs/bind_runner.rb:58`
  - `execution.image_resolved`, `execution.resource_provisioned` and
    related resource lifecycle events — `app/services/containers/provision.rb:315-993`
  - `execution.credential_classes_granted`,
    `execution.network_policy_granted` — `app/models/agent_run.rb:2924-2933`
  - execution requested/queued/admitted/rejected events —
    `app/temporal/activities/create_agent_run_activity.rb:97-102`,
    `app/jobs/process_run_queue_job.rb:225,1238`
  - `execution.emergency_disable_changed` and related control events —
    `app/services/execution_controls/run_impact.rb:262-273`
  - preview-session provisioning events —
    `app/jobs/preview_sessions/provision_job.rb:101`
- EARS specs `EXECUTION-AUDIT-004` and `EXECUTION-AUDIT-005` in
  `docs/intent/execution-audit/execution-audit-specs.md` are marked `[x]`
  and cite this code and its tests.

**Tests**:

- `spec/services/execution_audit_events/lifecycle_spec.rb`
- `spec/services/agent_runs/bind_runner_spec.rb` (`@spec EXECUTION-AUDIT-004`)
- `spec/services/containers/provision_spec.rb` (`@spec EXECUTION-AUDIT-004`, `@spec EXECUTION-AUDIT-005`)
- `spec/temporal/activities/create_agent_run_activity_spec.rb` (`@spec EXECUTION-AUDIT-004`)
- `spec/jobs/preview_sessions/provision_job_spec.rb` (`@spec EXECUTION-AUDIT-004`)

**Verdict**: Implemented — the gap identified in the 2026-08-21 closeout
(code search found `ExecutionAuditEvent.record!` only in the model test) no
longer applies; production call sites emit the event stream via
`ExecutionAuditEvents::Lifecycle`.

---

### Gap 2 (was Criterion 3): Pre-provisioning infrastructure spend-threshold enforcement — #3554

**Status**: Implemented.

**Shipped**:

- `Capacity::InfrastructureSpend` (`app/services/capacity/infrastructure_spend.rb`)
  accounts infrastructure spend from `agent_runs.external_metadata["infrastructure_spend"]`,
  windowed from `provisioning_started_at` through `completed_at`/`Time.current`,
  kept separate from `cost_cents`/`CostBudget`.
- `Capacity::InfrastructureSpendGuard` (`app/services/capacity/infrastructure_spend_guard.rb`)
  evaluates global/account/project/runner hourly and daily thresholds from
  `Capacity::InfrastructureLimits`, with a `call`/`preview` pair so
  capacity-aware host selection (`ProcessRunQueueJob#build_host_admission_evaluations`)
  can price candidate hosts without side effects, and
  `ProcessRunQueueJob#finalize_infrastructure_spend!` re-runs the real,
  side-effecting check exactly once against the winning host.
- `Capacity::RunAdmission#infrastructure_spend_denial`
  (`app/services/capacity/run_admission.rb:298-316`) wires the guard into the
  same pre-provisioning `infrastructure_denial` chain as the existing
  resource/provisioning-rate ceilings, so spend breaches deny admission
  before provisioning starts.
- A global daily breach escalates to an automatic global emergency
  `ExecutionControl` and clears it on recovery
  (`Capacity::InfrastructureSpendGuard`, `ExecutionControl`).
- Every first breach and recovery emits an `ExecutionAuditEvent`, a
  structured log entry, and an operator-visible `Notification` for
  account/project/runner scope.
- EARS specs `INFRA-SPEND-001` through `INFRA-SPEND-005` in
  `docs/intent/infrastructure-spend-thresholds/infrastructure-spend-thresholds-specs.md`
  are all marked `[x]`.

**Tests**:

- `spec/services/capacity/infrastructure_spend_spec.rb`
- `spec/services/capacity/infrastructure_spend_guard_spec.rb`
- `spec/services/capacity/run_admission_spec.rb`
- `spec/jobs/process_run_queue_job_spec.rb`
- `spec/services/projects/cost_dashboard_stats_spec.rb`

**Verdict**: Implemented — the gap identified in the 2026-08-21 closeout (no
spend-threshold check in `Capacity::RunAdmission`'s denial chain) no longer
applies.

## Remaining Criteria Re-Confirmed Unchanged

Criteria 1, 2, and 6 from the 2026-08-21 audit (aggregate resource/
provisioning-rate safety rails, emergency-disable controls, and provider
quotas documented as backstops) were already Implemented and remain
unchanged; re-run against current `main` with no regressions
(`spec/services/capacity/run_admission_spec.rb`,
`spec/models/execution_control_spec.rb`,
`spec/services/config/production_validator_spec.rb` all green).

## Conclusion

All RDR-061 acceptance criteria now have shipped code and passing test
evidence. RDR-061 moves from **Partially Implemented** to **Implemented** as
of 2026-08-23. No further child-gap issues are filed. Umbrella issue
[#3421](https://github.com/viamin/paid/issues/3421) and closeout issue
[#3601](https://github.com/viamin/paid/issues/3601) can both close.
