---
parent: MAINT
prefix: OPT
---

# Low-Level Design: Optimization Recipes and Bounded Repair Election

> **Draft — pending design acceptance.** This segment refines the planned
> RDR-075 maintenance capability for the optimization family tracked by
> [#4492](https://github.com/viamin/paid/issues/4492). It reconciles the
> owner decisions recorded for [#4495](https://github.com/viamin/paid/issues/4495)
> with RDR-075's report-only default. It authorizes neither maintenance
> implementation nor rollout; it becomes actionable only after the RDR-075,
> maintenance, and this segment's accepted artifacts are merged.

## Purpose

Optimization recipes let an authorized user ask a maintenance run to assess
non-functional opportunities without turning a curated type menu into a new
run type or a claim that every finding is safe to change. The initial menu is
Performance, Design / Architecture, Code Duplication, Security Hardening,
Cost / Resource Efficiency, Maintainability / Readability, and Test Coverage
& Quality. Entries are code-defined catalog data: display name, investigation
description, default metric hints, and an optional recipe definition. A new
entry requires catalog/recipe work, not an enum migration or project-admin
authoring surface.

The catalog is an aid to starting the existing maintenance workflow. UI, API,
and MCP expose the same selected type, optional free-text scope, and existing
project-scoped authorization. A selected type is recorded in the immutable
maintenance snapshot with the objective, scope, guidance, recipe version, and
tool provenance. An unknown or unmapped menu value becomes a custom-objective
maintenance run rather than an error. No selection remains valid as a broad
scope request; recommendations remain bounded by the resolved scope under the
maintenance contract, although an assessment may inspect relevant callers,
tests, and entry points as supporting evidence.

## Recipe and Evidence Contract

Every recipe declares its objective, assessment instructions, applicable
evidence collectors, validation guidance, and metric hints. It may be
tool-assisted or prompt-first. Tool attachment and provenance continue to use
RDR-073 and the maintenance contracts; a prompt-first recipe reports that no
tool check was planned rather than implying analyzer coverage. A collector
failure remains visible as incomplete coverage and therefore cannot produce a
`clean` or `completed` report under `MAINT-022`.

Code duplication, maintainability/readability, and performance are the first
implementation candidates ([#4494](https://github.com/viamin/paid/issues/4494)).
Duplication evidence is a candidate, not proof that code should be shared:
the assessment considers deliberate independence, framework callbacks, and
dynamic invocation. Maintainability and performance findings likewise state
their evidence, counterevidence, proposed action, validation plan, and any
coverage limitation. Security hardening, cost/resource efficiency,
architecture, and test-quality recipes are staged follow-ons
([#4496](https://github.com/viamin/paid/issues/4496)); test quality reconciles
with, rather than duplicates, RDR-075's future test-quality recipe.

Semantic assessment is performed through `agent_harness`. The structured
assessment names the claim, supporting and counterevidence, verification
disposition, repair scope, and a policy vocabulary assessment tier. The tier
is an agent judgment about the evidence, not a calibrated probability or a
number the control plane derives from text or raw analyzer output. Application
code validates response shape, records the immutable evidence, and compares
the returned tier with the user-selected policy threshold; it does not infer
semantic eligibility from keywords, counts, or analyzer confidence. This
separates Zero Framework Cognition's semantic work from deterministic policy
enforcement while retaining the owner-approved threshold selection.

## Bounded Repair Election

RDR-075 remains report-only by default. The sole proposed exception is an
optimization-run election made explicitly at run start
([#4495](https://github.com/viamin/paid/issues/4495)). It is never a
tenant-wide or recipe default. When omitted, the run produces the ordinary
report and findings remain available for manual M04 selection.

The election snapshot contains the selected assessment-tier threshold and
explicit per-repair cost and time limits. It is immutable after admission and
is presented equivalently by UI, API, and MCP. On a terminal, fully covered
report, the dispatcher may request a bounded repair through the existing M04
path only when all deterministic gates pass:

1. `maintenance_runs` is enabled and the initiating principal was authorized
   for both the maintenance start and the selected existing repair pathway.
2. The election exists, the report outcome is `completed`, and the finding is
   open, has a structurally valid agent assessment, and meets the elected
   tier threshold.
3. The finding is not Security Hardening and no prior auto-queued repair is
   active or completed for the same canonical finding identity and election
   lineage.
4. The proposed repair scope is no broader than the finding scope, and its
   explicit cost/time limits are present.

Each attempted handoff records report, occurrence, canonical-finding identity,
election, gate result, and resulting repair run or visible failure. A failed
gate is never silently discarded: the report shows why no repair was queued
and leaves the finding available for manual selection. Turning off the
maintenance guard stops new admissions and auto-queue handoffs, without
cancelling active repair runs or deleting reports.

Before a queued repair may apply its recommendation, M04 revalidates the
finding against the repair checkout whenever its target revision differs from
the report revision. Revalidation failure or scope expansion stops the repair
for visible human action; it neither applies stale evidence nor broadens the
repair. Per-repair budgets are enforced by the existing run budget machinery;
exhaustion preserves evidence and reports the exhausted outcome. Repeated
occurrences retain their required report history but cannot create duplicate
auto-queued repair work for the same canonical identity and election lineage.

Security Hardening is deliberately manual-selection-only. No assessment tier,
tool confidence, catalog entry, or run-start election overrides that default
deny. A separate accepted policy and accuracy/safety evidence would be needed
before that category could be eligible for automatic handoff.

## Delivery Boundaries and Traceability

[#4492](https://github.com/viamin/paid/issues/4492) is the tracking umbrella,
not an implementation prerequisite or source of runtime authorization. This
segment assigns executable work as follows:

| Claim family | Delivery issue |
| --- | --- |
| Code-defined catalog, curated menu, equivalent start surfaces, snapshot and custom fallback | [#4493](https://github.com/viamin/paid/issues/4493) |
| Initial duplication, maintainability, and performance recipes; evidence and honest coverage | [#4494](https://github.com/viamin/paid/issues/4494) |
| Per-run election, tier threshold, deterministic gates, budgets, revalidation, provenance, and idempotency | [#4495](https://github.com/viamin/paid/issues/4495) |
| Staged security, cost, architecture, and test-quality recipes; security manual-only rule | [#4496](https://github.com/viamin/paid/issues/4496) |

Each delivery also depends independently on accepted base maintenance intent
and its applicable M01–M04 contracts. This preparation does not close those
dependencies, enable the `maintenance_runs` guard, or authorize any runtime
implementation.

## Decisions & Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Type representation | Code-defined extensible catalog | Run enum; project-admin authoring in v1 | A catalog can add curated entries without schema churn while keeping the initial surface reviewable. |
| Eligibility judgment | Structured `agent_harness` assessment tier | Numeric confidence derived in application code; raw analyzer score | The judgment is semantic; code can deterministically enforce a selected policy without pretending to calibrate meaning. |
| Repair behavior | Per-run, opt-in bounded election | Tenant-wide default; repair during scanning | The owner decision preserves report-only behavior unless a user pre-authorizes a specific bounded handoff. |
| Security repair | Manual selection only | Include security when its tier meets the threshold | Security hardening needs separate accuracy and blast-radius review. |

## What This Is Not

- Not acceptance of RDR-075 or an enablement of maintenance runtime behavior.
- Not a general automatic-repair policy, a tenant-level switch, or a recipe
  default.
- Not authorization to calculate semantic confidence in framework code.
- Not authorization to auto-queue security repairs or expand a finding's
  repair scope.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [General maintenance LLD](../maintenance-runs/maintenance-runs-design.md)
- [#4492 optimization umbrella](https://github.com/viamin/paid/issues/4492)
- [#4495 owner decision record](https://github.com/viamin/paid/issues/4495)
