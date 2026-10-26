---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Maintenance Optimization Recipes and Bounded Repair

> **Draft — owner acceptance required.** This segment refines the draft
> [General Maintenance Runs](../maintenance-runs/maintenance-runs-design.md)
> contract and [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md).
> It records a reviewable policy prerequisite for the #4492 optimization
> family; it authorizes neither implementation nor rollout.

## Purpose

The optimization family gives a project owner a curated way to request a
report-only maintenance investigation without turning every selected category
into a new run type. A catalog entry supplies the objective, assessment
instructions, eligible evidence collectors, validation guidance, metric hints,
and repair posture. The catalog starts with performance, design/architecture,
code duplication, security hardening, cost/resource efficiency,
maintainability/readability, and test coverage/quality. Unknown selections
remain ordinary custom-objective maintenance requests rather than errors.

The family can later offer an opt-in automatic queue for a narrowly bounded
repair. It does not weaken RDR-075's default: a maintenance scan is report
only, automatic repair is off by default, and a repair remains a distinct
run through the existing M04 pathway.

## Tracks

| Deliverable | Claims | Status |
| --- | --- | --- |
| [#4493](https://github.com/viamin/paid/issues/4493) catalog and equivalent UI/API/MCP selection | MAINT-OPT-001–009 | executable after accepted prerequisites |
| [#4494](https://github.com/viamin/paid/issues/4494) first recipes | MAINT-OPT-010–019 | executable after catalog and base evidence contracts |
| [#4495](https://github.com/viamin/paid/issues/4495) opt-in bounded repair | MAINT-OPT-040–059 | executable only after policy acceptance and M04 |
| [#4496](https://github.com/viamin/paid/issues/4496) staged recipes | MAINT-OPT-020–025 | executable after the first recipes and accepted policy |

[#4492](https://github.com/viamin/paid/issues/4492) coordinates the family
and final acceptance. It is not an executable deliverable and is not evidence
that any child has shipped.

## Catalog and Recipe Contract

`MaintenanceOptimization::Catalog` is data/configuration, not an enum or a
migration. Each entry has a stable key, display name, description, assessment
instructions, allowed evidence collectors, validation guidance, metric hints,
and one repair posture: `manual_only`, `eligible_for_auto_queue`, or
`staged_default_deny`. The run snapshots the resolved entry/version with the
base objective, scope, guidance, pinned revision, and tool provenance so a
retry can explain the recipe actually assessed.

UI, authenticated API, and MCP expose the same selectable catalog and the
same authorization. Selection composes with a free-form objective, scope, and
guidance; it does not require a catalog entry. The base `maintenance_runs`
guard remains the only rollout guard and is default off. Disabling it stops
new investigations and new automatic queues but does not cancel an admitted
repair.

## Honest Evidence and Semantic Assessment

Collectors produce bounded, attributed structural evidence. `agent_harness`
performs the semantic assessment of whether a candidate is an optimization
finding, what counterevidence matters, whether the proposed repair is within
the finding's scope, and its discrete assessment standing. Paid must not
derive semantic fitness from keywords, a tool score, or locally calibrated
numeric confidence.

The structured assessment returns `unsupported`, `uncertain`, or `supported`,
with cited evidence and counterevidence. This standing is a judgment, not a
probability and not a claim of calibrated confidence. A raw tool confidence is
preserved separately. The policy default minimum standing is `supported`;
the per-run election may only narrow that requirement. Invalid, unavailable,
or stale assessments fail closed for automatic repair and remain reportable
findings for manual selection.

Every report states the recipe, completed and unavailable collectors,
provenance, evidence limits, assessment standing, and whether automatic repair
was considered. Prompt-first recipes honestly report that no tool collector
ran; tool absence never becomes clean coverage.

## Bounded Automatic-Repair Policy

The owner may elect `auto_queue_bounded_repairs` only when starting one
optimization maintenance run. It is false by default, never tenant-wide, and
is visible with the selected minimum standing and explicit per-repair cost and
time caps on UI, API, and MCP. The election is immutable at run start and
cannot broaden a more restrictive catalog posture.

After a `completed` report only, deterministic admission evaluates each open
canonical finding under a lock. It queues at most one repair only when all of
these gates pass:

1. the base guard remains enabled and the run's recorded election is true;
2. the catalog posture permits auto-queue and the assessment standing meets
   the snapshotted minimum;
3. the finding's proposed repair is bounded to its approved symbols/scope;
4. explicit cost and time caps are present and the existing repair pathway
   can reserve them;
5. current evidence and the target revision pass M04 stale-finding
   revalidation; and
6. no active or completed repair has the same canonical-finding identity and
   repair-policy snapshot idempotency key.

The report outcome, semantic standing, scope, snapshot values, revalidation
result, rejected gate, and repair linkage are durable provenance. A partial,
cancelled, or budget-exhausted report cannot auto-queue. A duplicate, stale,
over-budget, unassessed, or broadened repair produces a visible non-queue
outcome; it does not retry around the gate. The repair run enforces its own
caps and preserves evidence on exhaustion.

Security hardening is always `manual_only` until a separately accepted policy
changes that posture. Cost/resource efficiency, design/architecture, and test
coverage/quality begin `staged_default_deny`; their catalog presence does not
make them auto-queue eligible. These are authorization rules, not semantic
classifiers.

## Decisions and Alternatives

| Decision | Chosen | Rejected | Rationale |
| --- | --- | --- | --- |
| Optimization taxonomy | Extensible catalog entries | enum/schema migration per type | Recipes change independently and unknown selections can remain custom objectives. |
| Assessment policy | `agent_harness` discrete standing with cited evidence | local numeric confidence calibration | Semantic judgment belongs to the model; Paid can reliably enforce a declared standing but cannot manufacture calibrated semantics. |
| Automatic repair default | Per-run opt-in, default off | tenant-wide switch or automatic scan side effect | Preserves RDR-075 report-only default and gives each request explicit authority. |
| Queue timing | Only after a `completed` report | queue on partial evidence | Incomplete coverage is not sufficient authorization for an unattended repair. |
| Authorization | Deterministic gates after semantic assessment | model-controlled queueing | Budget, revision, scope, idempotency, and policy are control-plane responsibilities. |
| Security posture | Manual-only | inherited optimization eligibility | Security repairs require a distinct approved authority. |

## Acceptance Hold and Next Decision

This design reconciles the #4495 owner decisions, but owner acceptance is not
recorded. Keep #4636 open and surface an Inbox decision requesting acceptance
or amendment of: the discrete-standing replacement for “confidence threshold,”
the `supported` default, completed-report-only queueing, narrowing-only
election, manual-only security posture, staged default-deny categories, and
canonical-finding idempotency. Until that decision and the canonical-artifact
merge are recorded, implementation issues remain blocked and no rollout is
enabled.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [maintenance-runs LLD](../maintenance-runs/maintenance-runs-design.md)
- [#4492](https://github.com/viamin/paid/issues/4492), [#4493](https://github.com/viamin/paid/issues/4493), [#4494](https://github.com/viamin/paid/issues/4494), [#4495](https://github.com/viamin/paid/issues/4495), and [#4496](https://github.com/viamin/paid/issues/4496)
