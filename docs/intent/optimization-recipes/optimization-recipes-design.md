---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipes

> **Draft — pending owner acceptance.** This is the docs-only policy
> prerequisite for the RDR-075 optimization family. It does not accept
> RDR-075, enable `maintenance_runs`, or authorize runtime behavior. The
> required acceptance decision remains in [#4636](https://github.com/viamin/paid/issues/4636).

## Purpose

Optimization recipes are a curated family inside RDR-075 maintenance runs.
They let an authorized user investigate a selected optimization type while
retaining the maintenance run's pinned revision, scope, evidence, report, and
repair-handoff contracts. The catalog is extensible by entries and recipe
definitions; it is not an enum embedded in the run contract.

This leaf owns the optimization catalog, recipe selection, evidence posture,
and the narrowly pre-authorized automatic-repair policy. It consumes the
`MAINT` segment's maintenance lifecycle, finding identity, revalidation, and
authorized repair creation pathway. It does not alter RDR-075's report-only
default or create a second rollout guard.

## Catalog and Recipe Selection

The initial catalog contains Performance, Design / Architecture, Code
Duplication, Security Hardening, Cost / Resource Efficiency, Maintainability /
Readability, and Test Coverage & Quality. Each entry has a stable key,
display name, description, metric hints, and an optional recipe-definition
reference. UI, API, and MCP present the same catalog selection and preserve a
free-text maintenance objective when no catalog entry applies. An unknown or
unmapped selection becomes that custom objective; it is not a failed admission.

The selected catalog key, resolved recipe version, objective, scope, guidance,
and limits are immutable run-start provenance and survive retries. Scope may
name files, symbols, a feature, a page, or a free-text boundary. It bounds a
recommendation and any repair; it does not prevent the investigation from
reading callers, tests, framework entry points, or design artifacts needed to
support or refute the claim. Reports disclose that supporting inspection and
any coverage limitation.

## Evidence and Assessment

The first recipes are Code Duplication, Maintainability / Readability, and
Performance. Duplication and maintainability may use attached analyzers where
the RDR-075 tool contract admits them; Performance is prompt-first until a
credible collector is admitted. Tool output is evidence, never a conclusion:
similarity, a missing static reference, or a raw analyzer score cannot alone
justify consolidation, deletion, or repair. The report records tool provenance
when tools attach and explicitly records prompt-only or incomplete coverage.

Semantic assessment of a candidate, including whether counterevidence defeats
the recommendation, is made through `agent_harness` with a versioned,
structured rubric. The response includes an eligibility standing,
explanation, citations to the evidence and counterevidence, and a validation
plan. Code validates that response's shape and enforces authorization,
category, revision, budget, and idempotency gates; it does not infer semantic
meaning or calibrate a numerical probability. Raw tool confidence is never an
automatic-repair gate input. Unknown, malformed, or stale assessments fail
closed for automatic repair while remaining visible in the report.

## Bounded Automatic Repair

The maintenance default is report-only. An authorized user may make a
per-run, opt-in election at run start to auto-queue repairs for qualifying
findings. Omission has exactly report-only behavior. The election is neither a
tenant-wide nor recipe default and does not apply to schedules. It includes a
minimum assessment standing and explicit per-repair cost and time limits.
The election can narrow an entry's authorization only; it cannot elevate a
manual-only or default-deny category.

After a completed report, the deterministic gate admits a repair only when:

1. the run-start election is present and the selected catalog category permits
   automatic repair;
2. the structured `agent_harness` assessment satisfies the configured,
   ordered standing policy (the default minimum is `supported`);
3. the finding is within the elected scope, has a canonical identity, and has
   no existing automatic-repair idempotency key for that identity;
4. the existing M04 repair pathway can create a bounded repair with the
   captured cost/time limits; and
5. the source evidence is revalidated against the repair checkout whenever its
   target revision moved.

The gate records every rejection reason. A report that is `partial`,
`cancelled`, or `budget_exhausted` queues nothing. Each admitted repair links
to its report, occurrence, canonical finding, election, and assessment. A
budget-exhausted repair preserves its evidence under the base maintenance
contract. Repeated occurrences of a canonical finding do not create duplicate
repair work.

Security Hardening is manual-only until a separately approved accuracy and
safety review changes that standing. Cost / Resource Efficiency, Design /
Architecture, and Test Coverage & Quality are default-deny for automatic
repair until separate owner authorization supported by evaluation evidence.
They remain reportable and manually selectable through the existing repair
pathway.

## Issue Mapping and Dependencies

| Deliverable | Owning issue | Claims |
| --- | --- | --- |
| Catalog and type menu | [#4493](https://github.com/viamin/paid/issues/4493) | `MAINT-OPT-001`–`009` |
| First recipes and honest evidence | [#4494](https://github.com/viamin/paid/issues/4494) | `MAINT-OPT-010`–`025` |
| Opt-in bounded automatic repair | [#4495](https://github.com/viamin/paid/issues/4495) | `MAINT-OPT-030`–`035` |
| Staged types | [#4496](https://github.com/viamin/paid/issues/4496) | `MAINT-OPT-040`–`041` |

[#4492](https://github.com/viamin/paid/issues/4492) is tracking-only and owns
no executable claim. Each delivery remains independently blocked on base
maintenance acceptance, the RDR-075 tool-handoff evidence, and acceptance of
this draft in #4636. Merging this documentation does not satisfy those runtime
dependencies or permit rollout.

## Decisions & Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Catalog representation | Code-defined entries and recipe definitions | Run-contract enum; project-admin authoring UI | Entries extend without migrations while v1 needs a curated, reviewable menu. |
| Semantic eligibility | Versioned `agent_harness` assessment with an ordered standing | Raw analyzer score; calibrated numerical model probability | Semantic evidence is an AI judgment under ZFC; the available evidence does not establish calibrated numeric semantics. |
| Automatic repair authorization | Per-run opt-in election, default report-only | Tenant-wide or recipe default; scan side effect | Preserves the owner decision and RDR-075's separate investigation/repair authorization. |
| High-risk categories | Security manual-only; staged types default-deny | Election overrides category standing | The election narrows an authorization; it cannot silently create a new safety authorization. |
| Idempotency identity | Canonical finding identity | Report occurrence or maintenance run | Recurring reports need fresh occurrences without duplicate repair work. |

## What This Is Not

- Not acceptance of RDR-075 or an enabled maintenance rollout.
- Not a numerical-confidence calibration claim or a tool-score authorization.
- Not automatic security remediation or automatic repair from scheduled runs.
- Not a replacement for `MAINT-070`–`073` manual repair selection and
  revalidation.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [General Maintenance Runs LLD](../maintenance-runs/maintenance-runs-design.md)
- [#4636 design prerequisite](https://github.com/viamin/paid/issues/4636)
- [#4495 owner decisions](https://github.com/viamin/paid/issues/4495)
