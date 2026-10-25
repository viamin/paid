---
parent: PAID
prefix: OPT
---

# Low-Level Design: Optimization Recipe Catalog and Bounded Repair Policy

> **Draft — pending design acceptance.** This is the reviewable optimization
> prerequisite prepared by [#4636](https://github.com/viamin/paid/issues/4636).
> It reconciles the owner decisions recorded in
> [#4495](https://github.com/viamin/paid/issues/4495) with the report-only
> maintenance contract in [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
> and `MAINT-*`. It authorizes neither runtime implementation nor rollout.
> **Tracks #4636**; human acceptance of these precise revisions remains the
> concrete Inbox decision before #4493–#4496 can proceed.

## Purpose and Boundary

Optimization is a recipe family inside the planned RDR-075 maintenance
lifecycle. It uses a code-defined, extensible catalog to offer curated audit
types; it does not create a parallel run type, report model, tool provisioner,
or repair pathway. The base maintenance LLD owns run snapshots, finding
identity and occurrences, truthful report outcomes, tool provenance, repair
links, and the `maintenance_runs` rollout guard.

This leaf owns the optimization-specific catalog, recipe selection, semantic
assessment boundary, recommendation-scope rules, and the proposed narrow
auto-queue policy. The proposal depends independently on accepted base
maintenance intent and its implementation prerequisites, including #4604's
tool-handoff evidence. The tracking umbrella #4492 is not an executable
deliverable and does not authorize any child.

## Catalog and Recipe Selection

The catalog is code-defined in its first version. An entry has a stable key,
display name, explanation of what the recipe investigates, metric hints, and
an optional pointer to a recipe definition. Adding a type is an entry/recipe
change, not an enum migration. The initial curated menu is Performance, Design
/ Architecture, Code Duplication, Security Hardening, Cost / Resource
Efficiency, Maintainability / Readability, and Test Coverage & Quality.

The project UI, authenticated API, and MCP start surfaces present the same
catalog and authorization decision. A selected type composes with free-text
scope and guidance and is retained in the base maintenance snapshot across
retries. A missing or unmapped type selection falls back to a custom-objective
maintenance question; it is not a start error. A run may also start without a
type under `MAINT-011` when it supplies nonblank guidance.

The first implemented recipes are code duplication, maintainability /
readability, and performance. Tool output is evidence rather than a verdict;
performance may run prompt-first where no credible tool attaches. Follow-on
security, cost, architecture, and test-quality recipes land only through
catalog entries and their own evidence evaluation. The test-quality recipe
must reconcile with RDR-075's planned test-quality work rather than duplicate
it.

## Scope and Honest Evidence

The user-facing scope bounds recommendations, not the supporting inspection
needed to establish or reject them. A recipe may inspect callers, tests,
framework entry points, and design material outside that scope, but reports
must identify that evidence and explain any recommendation whose proposed
change extends beyond the requested scope. Expanding a repair remains an
explicit human authorization under `MAINT-070`–`MAINT-072`.

Every optimization report follows `MAINT-020`–`MAINT-025`: it distinguishes
completed coverage from partial coverage, preserves tool provenance and raw
tool output separately from assessment, and records counterevidence and
limitations. A tool match, similarity metric, or absent static reference never
by itself establishes a repair recommendation. A report without a credible
tool path is honest about prompt-first coverage; an unavailable planned tool
remains partial, never clean.

## Semantic Assessment and Deterministic Gates

`agent_harness` performs semantic assessment of evidence: whether a candidate
is a finding, its reasoning, counterevidence, proposed bounded action, and its
structured eligibility assessment for the policy. The assessment is evidence
with model/prompt provenance, not a direct authorization and not a calibrated
numeric truth claim. This preserves Zero Framework Cognition: application code
does not infer meaning from text, titles, labels, or metrics.

Code performs only deterministic gates. It verifies the per-run auto-queue
election, the default-off `maintenance_runs` guard, existing repair-path
authorization, an explicit repair cost/time budget, a valid canonical finding
identity, no existing repair work for that policy/finding occurrence, and
revalidation against the repair checkout when the source revision is stale.
The approved policy may compare the agent's structured eligibility output to a
configured threshold, but this design deliberately does not invent a numeric
scale, default, or calibration semantics. A failed gate must leave the report
and finding visible with an actionable reason; it must not silently queue or
silently drop work.

## Proposed Bounded Automatic Repair

The owner decisions recorded in #4495 are preserved exactly as a narrow future
policy:

- The election is per run, explicit, and off by default; it is never a tenant
  default or a recipe default. Omitting it is exactly report-only behavior.
- Qualifying findings may create a separate bounded repair through the normal
  M04 handoff, with source report/finding provenance and explicit per-repair
  time and cost budgets. Exhaustion preserves collected evidence.
- Canonical finding identity prevents duplicate auto-queued repair work from
  repeated occurrences. Idempotency does not erase later report occurrences.
- A repair checkout different from the report revision forces revalidation
  before a recommendation can apply. Revalidation failure is visible and
  cannot silently authorize repair.
- Security Hardening is excluded from auto-queue. Security repairs remain
  manual selection only unless a dedicated accuracy and safety policy review
  separately accepts a change.

This policy does not make an audit mutate code, make tools blocking, relax a
repair pathway's authorization, or cancel active repair work when future
admission is disabled. Disabling the maintenance guard stops new admissions
and auto-queues while retaining reports and active-run lifecycle behavior.

## Delivery Mapping

| Deliverable | Scoped intent | Owning issue |
| --- | --- | --- |
| Catalog and equivalent selection surfaces | `OPT-001`–`OPT-004` | [#4493](https://github.com/viamin/paid/issues/4493) |
| First recipes and honest evidence | `OPT-010`–`OPT-013` | [#4494](https://github.com/viamin/paid/issues/4494) |
| Opt-in bounded auto-queue policy | `OPT-020`–`OPT-027` | [#4495](https://github.com/viamin/paid/issues/4495) |
| Staged follow-ons and security exclusion | `OPT-030`–`OPT-033` | [#4496](https://github.com/viamin/paid/issues/4496) |
| Coordination/final audit only | No implementation claims | [#4492](https://github.com/viamin/paid/issues/4492) |

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Catalog representation | Code-defined extensible entries with optional recipe pointers | Run-contract enum; project-admin authoring UI | The curated first version needs a stable menu without migrations or an authoring product; entries keep later extension local to the catalog. |
| Semantic judgment | Structured `agent_harness` assessment; deterministic code gates its use | Heuristics over text/metrics; code-calibrated confidence score | Whether evidence supports an optimization is semantic. Code can safely enforce authority, budget, identity, and revision facts without pretending to judge meaning. |
| Automatic repair | Per-run, opt-in, bounded follow-up through the existing repair path | Scan-side-effect repair; tenant-wide or recipe-default enablement | Preserves #4495's owner decision while respecting RDR-075's separation of investigation from repair. |
| Security treatment | Manual repair selection pending a dedicated policy review | Include security with general auto-queue | Security findings carry a distinct accuracy and blast-radius risk that this proposal does not resolve. |

## Open Questions & Future Decisions

### Resolved

1. ✅ #4495's per-run opt-in, explicit budget, revalidation, bounded-scope,
   and idempotency decisions are retained without broadening their authority.
2. ✅ A confidence threshold remains a policy comparison over structured agent
   output; no calibrated numerical semantics are asserted by this design.

### Deferred

1. The concrete structured eligibility schema, threshold representation, and
   budget default values require implementation-time design after this policy
   receives human acceptance; they must not be inferred as numerical truth.
2. The exact repair idempotency key and persistence location must extend the
   accepted `MAINT-026`/`MAINT-027` identity contract during #4495, without
   suppressing report occurrences.
3. Each follow-on recipe needs its own evidence evaluation before delivery;
   security auto-queue needs its own dedicated policy review.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [Maintenance runs LLD](../maintenance-runs/maintenance-runs-design.md) and
  its `MAINT-*` EARS contract
- [#4636](https://github.com/viamin/paid/issues/4636) — this documentation-only prerequisite
- [#4492](https://github.com/viamin/paid/issues/4492)–[#4496](https://github.com/viamin/paid/issues/4496)
