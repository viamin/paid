---
parent: PAID
prefix: OPT
---

# Low-Level Design: Optimization Recipes and Bounded Repair Policy

> **Draft — pending owner acceptance.** This is a docs-only prerequisite for
> RDR-075 optimization work. It reconciles the owner decisions recorded in
> [#4495](https://github.com/viamin/paid/issues/4495) with the draft base
> maintenance contract; it authorizes neither maintenance admission nor repair
> dispatch. Base-maintenance acceptance remains independently owned by
> [#4635](https://github.com/viamin/paid/issues/4635), and live tool-handoff
> evidence remains owned by [#4604](https://github.com/viamin/paid/issues/4604).

## Purpose

Optimization is a maintenance recipe family for non-functional improvements:
making a project more efficient without adding product behavior. It reuses the
RDR-075 maintenance lifecycle — pinned revision, report-only investigation,
honest coverage, canonical findings, and bounded repair handoff — rather than
creating a second audit or repair system.

This leaf owns the optimization catalog, recipe-selection contract, and the
narrow policy that may auto-queue a bounded repair after an optimization
report. The base `maintenance-runs` leaf remains authoritative for run
admission, report/finding storage, schedules, tool attachment, and normal
manual repair selection. A maintenance scan itself never changes source code
or opens a PR.

## Catalog and Recipe Selection

The catalog is code-defined and extensible: each entry has a stable key,
display name, investigation description, metric hints, and an optional
underlying recipe definition. Adding a type is a catalog/recipe entry, not an
enum migration. The initial curated menu is Performance, Design / Architecture,
Code Duplication, Security Hardening, Cost / Resource Efficiency,
Maintainability / Readability, and Test Coverage & Quality.

UI, authenticated API, and MCP start surfaces present the same menu and
authorization decision. A selected type snapshots with the maintenance
objective, scope, guidance, pinned revision, and recipe version and survives
retries. No selection is required: an unknown or unmapped selection becomes a
custom-objective maintenance run rather than an error.

Scope bounds recommendations, not the evidence an investigation may inspect.
The recipe may examine callers, tests, framework entry points, and design
artifacts outside a requested file, feature, or page when that evidence is
needed to assess a claim. The report must identify that supporting evidence;
a proposed repair remains bounded to the approved finding, and a broader
change requires explicit human authorization.

The first implementation slice contains code duplication, maintainability,
and performance. Duplication and maintainability may use RDR-073-backed
collectors when their contract permits; analyzer output alone is not a repair
recommendation. Performance begins prompt-first when no credible profiler is
attached, and its report states that coverage limitation. Security, cost,
architecture, and test-quality recipes are later staged entries. Test-quality
must reconcile with the RDR-075 planned test-quality recipe rather than
duplicate it.

## Evidence and Semantic Assessment

Collectors and deterministic checks provide bounded evidence; they do not
decide whether a code pattern merits a recommendation. Each finding assessment
is an `agent_harness` request over the pinned revision, recipe instructions,
requested scope, bounded supporting and counterevidence, and the applicable
policy/rubric version. Its structured response records the claim, affected
symbols, proposed action, validation plan, coverage limitations, and an
explanation of why the evidence does or does not support repair.

The assessment also returns a policy-defined repair-eligibility disposition.
This is a semantic judgment made by `agent_harness`, not a numerical score
calibrated or interpreted by Rails. A policy may name a confidence threshold,
but its versioned rubric is supplied to the assessor and the persisted result
is the assessor's structured eligibility outcome with evidence. Rails validates
the response shape and enforces authorization, revisions, budgets, category
exclusions, and idempotency deterministically. It does not infer eligibility
from text, tool output, or an invented numeric cutoff.

## Per-Run Bounded Auto-Queue Policy

An authorized caller may elect auto-queue at optimization-run start. The
election is per-run, snapshots the policy/rubric version and explicit repair
cost/time limits, and defaults to false when omitted. It is never a tenant-wide
or recipe default. The full report remains available regardless of election;
findings that are not eligible for auto-queue remain available for manual
selection through the base maintenance pathway.

After report completion, a candidate may be dispatched only when all of these
deterministic gates pass:

1. `maintenance_runs` is enabled and the run's elected policy is enabled.
2. The original caller was authorized to make the election and the existing
   repair-creation pathway authorizes the bounded target.
3. The persisted structured assessment is eligible under the snapshotted
   policy and has complete, honest evidence for that finding.
4. The finding category is not Security Hardening. Security findings are
   manual-selection-only until a separately accepted policy changes that
   default-deny rule.
5. The repair has explicit per-run cost/time limits and a scope derived from
   the selected finding; it cannot widen scope automatically.
6. The source evidence is revalidated against the repair checkout whenever
   its target revision differs from the report revision. Revalidation failure
   is visible and prevents application; it never silently drops or proceeds.
7. An atomic idempotency record keyed by the run's election and canonical
   finding identity has not already created or reserved repair work. Repeated
   finding occurrences therefore do not enqueue duplicate repairs.

Disabling maintenance admission prevents new elections and new auto-queues but
does not cancel active repair runs or delete reports. Budget exhaustion follows
the base maintenance evidence-preservation contract.

## Decisions and Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Catalog representation | Code-defined extensible catalog with a presentation menu | Run-contract enum; project-admin authoring UI | Recipe definitions are the durable behavior source; an enum makes additions a schema concern, while authoring UI is outside v1. |
| Scope interpretation | Scope bounds recommendations, not supporting evidence access | Restrict all inspection to named paths | A sound recommendation can require callers, tests, or framework-entry evidence; repair expansion still needs explicit authorization. |
| Confidence policy | `agent_harness` returns rubric-backed eligibility; Rails applies deterministic gates | Rails-calibrated numerical score; keyword/tool-output heuristics | Semantic confidence is a judgment. ZFC keeps that judgment in the agent while retaining auditable policy and mechanical enforcement in code. |
| Automatic repair | Per-run opt-in auto-queue after a report, default off | Scan-side-effect repair; tenant/recipe-default repair; manual-only forever | This preserves #4495's owner decision without weakening RDR-075's initial report-only scan boundary. |
| Security repair | Manual selection only | Include security in generic auto-queue | Security hardening needs a dedicated accuracy and blast-radius policy review. |

## Delivery Map and Acceptance Boundary

| Scoped claim | Executable owner |
| --- | --- |
| Catalog, curated menu, custom fallback, and snapshot retention | [#4493](https://github.com/viamin/paid/issues/4493) |
| Duplication, maintainability, and prompt-first performance recipes with honest evidence | [#4494](https://github.com/viamin/paid/issues/4494) |
| Per-run election, eligibility, budgets, revalidation, idempotency, and security exclusion | [#4495](https://github.com/viamin/paid/issues/4495) |
| Staged security, cost, architecture, and test-quality recipes | [#4496](https://github.com/viamin/paid/issues/4496) |
| Family tracking and final evidence coordination | [#4492](https://github.com/viamin/paid/issues/4492) only; it is not an executable prerequisite deliverable |

No runtime work follows from this document. Owner acceptance must identify the
precise revision of this LLD and its EARS, be recorded through the authorized
review/decision path, and merge the accepted artifacts before #4636 closes.
Until then a preparation PR must use `Tracks #4636`, retain the review hold,
and leave #4636 open with an Inbox decision requesting that acceptance.

## What This Is Not

- Not approval to enable `maintenance_runs`, dispatch a maintenance run, or
  roll out the catalog.
- Not a replacement for RDR-075's report, finding, tool, or repair contracts.
- Not authority to auto-queue Security Hardening repairs.
- Not a calibrated numerical-confidence system or a semantic rule engine in
  Rails.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [General Maintenance Runs LLD](../maintenance-runs/maintenance-runs-design.md)
- [#4492 optimization umbrella](https://github.com/viamin/paid/issues/4492)
- [#4495 owner decisions](https://github.com/viamin/paid/issues/4495)
- [#4636 design prerequisite](https://github.com/viamin/paid/issues/4636)
