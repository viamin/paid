---
parent: PAID
prefix: OPT
---

# Low-Level Design: RDR-075 Optimization Recipes and Bounded Repair Policy

> **Draft — pending human design acceptance.** This leaf refines the planned
> RDR-075 maintenance capability; it does not amend its report-only default or
> authorize implementation. It is the preparation prerequisite for
> [#4493](https://github.com/viamin/paid/issues/4493)–[#4496](https://github.com/viamin/paid/issues/4496), not an executable child of
> the tracking umbrella [#4492](https://github.com/viamin/paid/issues/4492).

## Purpose

Optimization is a maintenance recipe family for non-functional, contracting
investigations. It reuses the RDR-075 maintenance run, pinned revision,
report, finding identity, authorization, and `maintenance_runs` rollout guard;
it neither introduces another run lifecycle nor enables that guard. A user may
select a curated optimization type or supply a free-text objective. A report
remains the normal result. The only proposed exception is a narrowly bounded,
per-run preauthorization that can queue repair work after the report, subject
to the gates in this design.

This design records the owner decisions in #4495 as reviewable intent. Human
acceptance of this document and its EARS is still required before those
decisions can authorize runtime behavior.

## Catalog and Recipe Selection

The optimization catalog is code-defined and extensible by entries, not a
database enum or project-admin authoring surface. Its initial curated types
are Performance, Design / Architecture, Code Duplication, Security Hardening,
Cost / Resource Efficiency, Maintainability / Readability, and Test Coverage
& Quality. Each entry supplies a display name, investigation description,
default metric hints, and an optional underlying recipe reference.

The UI, authenticated API, and MCP start surfaces present the same catalog
selection and free-text scope/guidance contract. A menu is presentation over
the catalog, not a restriction on maintenance objectives: no selection remains
valid, and a value with no mapped catalog entry becomes a custom-objective
maintenance run rather than an admission error. The selected entry or custom
objective is snapshotted with the existing run inputs and retained by retries.

The first implementation set is Code Duplication, Maintainability /
Readability, and Performance. The later Security Hardening, Cost / Resource
Efficiency, Design / Architecture, and Test Coverage & Quality recipes are
separate staged work. Test-quality design must reconcile with RDR-075's future
test-quality recipe rather than duplicate it.

## Scope and Evidence

Requested files, features, pages, paths, or symbols bound the recommendation,
not access to corroborating evidence. An assessment may inspect callers,
tests, framework entry points, design documents, and other repository context
when needed to verify or refute a claim. The report identifies the requested
scope, supporting inspection, exclusions, completed checks, and incomplete
checks. It must not imply clean coverage when planned evidence collection was
partial, cancelled, or budget-exhausted.

Analyzer output is candidate evidence, never an automatic conclusion. Semantic
assessment — including whether similar code is intentionally independent,
dynamically invoked, or safe to change — is performed through `agent_harness`.
The structured assessment records the claim, supporting and counterevidence,
proposed action, validation plan, coverage limitations, and a verification
disposition. Prompt-only recipes state that evidence path honestly. Native and
attached tools retain RDR-075/RDR-073 provenance and isolation requirements.

## Bounded Automatic Repair Policy

The base RDR-075 rule remains: a maintenance scan is report-only and never
creates repair work as its side effect. For an optimization run only, the user
may explicitly elect an auto-queue policy at run start. Omission is report-only
behavior. The election is not a tenant-wide setting, a recipe default, or an
implicit consequence of selecting an optimization type. It is immutable run
provenance containing its confidence policy and explicit cost/time limits for
each possible repair run.

`agent_harness` makes the semantic assessment and returns a schema-validated
confidence disposition for each finding. The policy's confidence threshold is
an ordered selector over that disposition, not a calibrated numeric claim and
not a score inferred or recalibrated by framework code. Code may validate the
structured response and compare its declared disposition with the snapshotted
threshold, but it must not decide what the finding means, synthesize a
confidence score, or override the assessment by heuristic.

After a completed report, the system may use only deterministic gates to admit
an auto-queued repair: the maintenance guard and equivalent caller
authorization are active; a per-run election exists; the finding meets the
snapshotted policy; the finding is not security-category; its approved repair
scope is bounded to that finding; explicit cost/time limits are present; and
no repair is already linked for the canonical finding identity. The existing
M04 repair pathway remains the sole creator of repair work and preserves its
report/finding provenance. A repeated occurrence of that identity therefore
cannot queue duplicate automatic work. Manual selection remains available and
uses the existing M04 authority independently.

Before applying a recommendation, an auto-queued repair revalidates the source
evidence against its repair checkout when its target revision differs from the
source report. Revalidation failure or inability to establish the bounded
scope is visible and stops the repair; it is never a silent fallback or scope
expansion. Budget exhaustion preserves evidence under the maintenance contract.
Security Hardening findings are report-only and manual-selection-only until a
separate approval explicitly changes that category's policy.

## Delivery Boundaries and Issue Mapping

| Scoped claim | Executable prerequisite | Boundary |
| --- | --- | --- |
| Code-defined catalog, seven curated types, menu parity, custom-objective fallback, and run snapshot | [#4493](https://github.com/viamin/paid/issues/4493) | Uses M01 admission and the default-off maintenance guard. |
| Duplication, maintainability, and performance recipes with honest evidence and first evaluation | [#4494](https://github.com/viamin/paid/issues/4494) | Uses M02 reports and M03 tool integration; performance may be prompt-first. |
| Per-run election, agent-owned confidence disposition, deterministic gates, budgets, revalidation, bounded scope, and idempotency | [#4495](https://github.com/viamin/paid/issues/4495) | Uses M04; no tenant/recipe default and no security auto-queue. |
| Staged security, cost, architecture, and test-quality recipes; manual-only security repair | [#4496](https://github.com/viamin/paid/issues/4496) | Reconciles test quality with RDR-075; security policy needs separate approval. |
| Family coordination and final evidence audit | [#4492](https://github.com/viamin/paid/issues/4492) | Tracking umbrella only; it authorizes no implementation. |

Base maintenance acceptance and its implementation dependencies remain
independent prerequisites for every executable row. This preparation does not
depend on closing #4492 or its runtime children.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Optimization representation | Code-defined catalog over RDR-075 recipes | Hard enum; separate optimization run type; project-authored catalog | Entries preserve extensibility and reuse the maintenance lifecycle without making type selection a migration or a second authorization surface. |
| Recommendation scope | Requested scope bounds recommendations, not corroborating inspection | Restrict all evidence reads to requested paths | Cross-cutting callers, tests, and framework conventions are often necessary to avoid unsafe recommendations; the report must disclose them. |
| Semantic confidence | `agent_harness` structured disposition with a policy threshold | Framework-generated numeric score or title/keyword heuristics | Meaning and confidence are semantic judgments; framework code can only enforce a schema and a declared policy comparison. |
| Automatic repair | Per-run, opt-in preauthorization with deterministic gates | Tenant/recipe default; scan-side repair; universal manual-only policy | This preserves the #4495 owner decision while keeping RDR-075's report-only default and existing M04 repair authority. |
| Security repairs | Manual selection only | Include security in the auto-queue policy | Security hardening requires a dedicated accuracy and blast-radius approval. |

## Open Questions & Future Decisions

1. Human acceptance must confirm this precise draft policy and EARS before any
   runtime child begins. The preparation PR must use **Tracks** and remain in
   the Inbox until that decision is recorded.
2. #4495 implementation chooses the approved `agent_harness` response schema
   and policy input representation; it must preserve the non-numeric,
   agent-owned semantic boundary specified here.
3. Each staged recipe needs its own evidence evaluation before it is admitted;
   a catalog entry alone does not demonstrate useful or safe recommendations.

## What This Is Not

- Not acceptance of RDR-075 or its maintenance LLD/EARS.
- Not implementation, feature-flag enablement, or a rollout authorization.
- Not a general authorization for automatic repair or for security repairs.
- Not a replacement for M04's repair creation, authorization, revalidation,
  provenance, or bounded-work contracts.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [General Maintenance Runs LLD](../maintenance-runs/maintenance-runs-design.md)
  and [EARS](../maintenance-runs/maintenance-runs-specs.md)
- [#4636](https://github.com/viamin/paid/issues/4636), the docs-only
  preparation task
- [#4495](https://github.com/viamin/paid/issues/4495), owner decision record
