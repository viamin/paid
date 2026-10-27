---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipes and Bounded Repair Election

> **Preparation draft — pending owner acceptance.** Tracks
> [#4636](https://github.com/viamin/paid/issues/4636). This child of
> [`maintenance-runs`](../maintenance-runs/maintenance-runs-design.md) reconciles the owner
> decisions recorded in [#4495](https://github.com/viamin/paid/issues/4495)
> with RDR-075's report-only maintenance contract. It authorizes neither
> implementation nor rollout. A preparation PR must use `Tracks #4636`; #4636
> remains open with an Inbox decision until a human accepts and merges these
> canonical artifacts.

## Purpose

The optimization family is a catalog of maintenance recipes for improving a
project without adding product functionality. It reuses the maintenance run,
scope, evidence, report, and bounded repair contracts. The catalog is an
extensible presentation and recipe-selection layer, not a new `AgentRun` enum
or a second maintenance lifecycle.

The initial curated types are Performance, Design / Architecture, Code
Duplication, Security Hardening, Cost / Resource Efficiency, Maintainability /
Readability, and Test Coverage & Quality. A selection is optional: an
unmapped value becomes a custom-objective maintenance run, and a free-text
objective remains valid. Catalog entries provide a display name, what the
recipe investigates, metric hints, and the underlying recipe definition when
available. They do not promise that a metric will improve or that a finding
must have a repair.

## Scope and Evidence

An optimization request records its selected type, objective, scope, guidance,
recipe version, pinned revision, and resolved tools on the maintenance-run
snapshot. Requested scope bounds recommendations; it does not prevent the
recipe from inspecting callers, tests, framework entry points, or design
documents needed to assess a candidate. Reports disclose that supporting
inspection and any coverage limitation. A repair may not broaden past the
approved finding merely because supporting evidence was broader.

Recipes return report evidence honestly. Code duplication, maintainability,
and performance are the first delivery candidates (#4494): duplication and
complexity may use RDR-073 collectors where credible, while performance starts
prompt-first when no suitable collector attaches. Similarity, an absent static
reference, or a metric hint alone never establishes that a consolidation,
deletion, or rewrite is appropriate. Security, cost, architecture, and test
quality are staged follow-ons (#4496); test quality must reconcile with the
base RDR-075 recipe rather than duplicate it.

## Semantic Assessment and Deterministic Control

The meaning-based assessment of a candidate — whether evidence supports the
claim, counterevidence, likely repair boundary, and validation plan — is made
through `agent_harness` using a structured response. It must retain evidence
and counterevidence in the report. Tool output is evidence, not a repair
decision.

The response may assign an eligibility confidence **band** from the ordered,
policy-defined set selected at run start. A band records the agent's
explanation of the current evidence; it is not a calibrated probability,
numeric score, or code-derived semantic heuristic. The configured threshold
selects which bands may proceed to the next deterministic gate. Code only
validates the response shape and enforces that ordering; it does not infer a
band from text, symbols, tool scores, or keywords.

The precise initial band names, their default threshold, whether dispatch is
limited to `completed` reports, and the default-deny standing of later recipe
types are pending owner acceptance in #4636. Until that decision is recorded,
the policy is documentation only and no band can authorize dispatch. Any
missing, malformed, stale, or rubric-incompatible assessment fails closed.

No semantic response itself authorizes a repair. The control plane
deterministically evaluates the captured election, `maintenance_runs` guard,
category allowlist, threshold ordering, explicit per-repair cost and time
budgets, source-report/finding provenance, current repair authorization,
idempotency key, and revision revalidation result. A failed or unavailable
gate is a visible non-dispatch outcome with its reason; it must not silently
drop a qualifying finding.

## Bounded Automatic Repair Election

RDR-075's baseline is manual selection through MAINT-070–MAINT-073. The only
proposed exception is an **opt-in, per-run election** for optimization runs.
It is off by default, never a tenant-wide, project-wide, recipe-wide, or
catalog-default switch. UI, authenticated API, and MCP start surfaces capture
the same election with its confidence-band threshold and explicit per-repair
cost/time budgets. Omitting it is exactly report-only behavior.

After a completed report, an elected finding may be queued only through the
existing M04 repair pathway. The queued work is bounded to the selected
finding and retains report/finding provenance. Before a repair acts, M04
revalidates evidence against the repair checkout whenever its revision differs
from the report revision. Broader scope, stale or failed revalidation, missing
authorization, a disabled guard, exhausted budget, or a duplicate active or
completed repair lineage stops automatic dispatch and remains visible for
manual follow-up.

Security Hardening is excluded from this election. Security findings remain
report-only with manual repair selection until a separate accepted safety and
accuracy policy explicitly changes that category's default-deny rule. No
catalog entry, threshold, or generic confidence band can override it.

A recurring maintenance schedule cannot carry this election: it is a person’s
per-run choice at run start, not a standing schedule, recipe, project, or
tenant default.

## Delivery Mapping

| Deliverable | Scoped claims | Issue |
| --- | --- | --- |
| Extensible catalog, optional menu, retained selection, custom-objective fallback | MAINT-OPT-001–005 | [#4493](https://github.com/viamin/paid/issues/4493) |
| Initial duplication, maintainability, and prompt-first performance recipes with honest evidence | MAINT-OPT-010–014 | [#4494](https://github.com/viamin/paid/issues/4494) |
| Per-run opt-in election, deterministic gates, budgets, revalidation, provenance, and idempotency | MAINT-OPT-020–029 | [#4495](https://github.com/viamin/paid/issues/4495) |
| Staged security, cost, architecture, and test-quality recipes; security manual-only rule | MAINT-OPT-030–034 | [#4496](https://github.com/viamin/paid/issues/4496) |

[#4492](https://github.com/viamin/paid/issues/4492) is the tracking umbrella
and final evidence audit, not an executable prerequisite or delivery owner.
All four deliverables independently retain RDR-075 acceptance, its
`maintenance_runs` default-off guard, and the base implementation dependencies.

## Decisions & Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Catalog shape | Code-defined extensible entries with optional menu selection | Run enum; project-admin authoring UI | Entries evolve without schema churn; owner authoring is outside v1. |
| Assessment | `agent_harness` structured semantic assessment plus deterministic gates | Tool score or code heuristic as repair authority | ZFC places meaning with the agent and authorization/state with code. |
| Confidence policy | Ordered eligibility bands selected by a captured threshold | Invented calibrated numeric score | Preserves the owner’s threshold decision without claiming unmeasured numerical calibration. |
| Automatic repair | Per-run, off-by-default bounded election | Scan-side repair; tenant or recipe default | Maintains RDR-075's separation of investigation and repair except for a narrowly pre-authorized handoff. |
| Security category | Manual-only | Generic auto-queue eligibility | Security blast radius needs separately accepted safety and accuracy evidence. |

## What This Is Not

- Not acceptance of RDR-075 or authorization to ship maintenance runtime.
- Not an automatic change, merge, or security-repair policy.
- Not a replacement for M04's authorization, revalidation, provenance, or
  bounded-scope requirements.
- Not a reason to close #4636, #4492, or any child issue before human review
  and the applicable implementation evidence.

## References

- [RDR-075](../../../rdrs/RDR-075-general-maintenance-runs.md)
- [Maintenance runs LLD](../maintenance-runs-design.md) and
  [EARS](../maintenance-runs-specs.md)
- [#4492](https://github.com/viamin/paid/issues/4492),
  [#4493](https://github.com/viamin/paid/issues/4493),
  [#4494](https://github.com/viamin/paid/issues/4494),
  [#4495](https://github.com/viamin/paid/issues/4495), and
  [#4496](https://github.com/viamin/paid/issues/4496)
