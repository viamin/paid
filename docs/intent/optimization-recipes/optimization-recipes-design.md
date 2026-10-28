---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipes

> **Draft — pending owner acceptance.** This leaf extends the draft
> [general-maintenance-runs LLD](../maintenance-runs/maintenance-runs-design.md)
> and RDR-075. It is the candidate separately approved policy that RDR-075
> requires before automatic repair. It authorizes neither implementation nor
> rollout while RDR-075 and this design remain unaccepted.

## Purpose

Optimization recipes are report-only maintenance investigations for improving
non-functional qualities without adding product functionality. A code-defined
catalog presents curated types while preserving the maintenance run's existing
recipe/objective, scope, guidance, pinned revision, report, and finding
contracts. The initial catalog types are Performance, Design / Architecture,
Code Duplication, Security Hardening, Cost / Resource Efficiency,
Maintainability / Readability, and Test Coverage & Quality.

This segment owns catalog selection, recipe evidence, semantic
repair-eligibility assessment, and the candidate bounded automatic-repair
policy. It consumes the maintenance-run lifecycle and RDR-073 tool lifecycle;
it does not create another tool catalog, execution boundary, repair pathway,
or rollout mechanism.

## Catalog and Scope Contract

The catalog is code-defined. Each entry has a stable key, display name,
description, metric hints, a recipe-definition reference when available, and a
repair standing: `auto_eligible`, `manual_only`, or `default_deny`. Adding a
type is a catalog/recipe change, never an enum migration or an administrator
authoring workflow. A missing catalog mapping becomes the existing
custom-objective maintenance run rather than an admission error.

The UI, authenticated API, and MCP start surfaces present the same curated menu
and retain the selected type in the immutable run snapshot. Selection remains
optional. A scope can name paths, symbols, or a free-form natural-language
target such as a feature or application page. Scope bounds recommendations,
not supporting inspection: agents may examine callers, tests, entry points, and
design documents outside it to establish or refute a claim. Any recommended
repair beyond the approved finding requires explicit human authorization.

## Recipes and Honest Evidence

The first delivery recipes are Code Duplication, Maintainability / Readability,
and Performance. A recipe defines its objective, investigation instructions,
applicable collectors, validation guidance, and metric hints.

Code Duplication uses available analyzer evidence (for example PMD CPD or
Ruby-oriented duplication analysis) as candidate evidence only. Similarity,
missing static references, or thin test coverage never by themselves establish
that code should be consolidated or deleted; deliberate independence,
framework callbacks, reflection, external contracts, and compatibility remain
counterevidence to assess. Maintainability may use complexity evidence where
available, while Performance is prompt-first until a credible profiling
collector is attached. All tool versions/configuration and prompt-only paths
are retained as evidence provenance. A missing applicable tool is not a
failure; a planned tool that cannot complete produces the base report's
incomplete coverage rather than a false clean result.

Semantic judgment is performed through `agent_harness` using a structured,
versioned rubric. Application code performs only structural validation and
deterministic policy/state transitions. Raw analyzer confidence and model
probabilities are evidence, not calibrated eligibility values and never a
numeric authorization gate.

## Semantic Repair-Eligibility Assessment

For each candidate finding, `agent_harness` returns a schema-constrained
assessment with cited supporting and counterevidence, rubric version, and one
of these ordered standings: `strong`, `supported`, `exploratory`,
`insufficient`, or `unknown`. `unknown` is explicit and never qualifies.

The standing is a bounded semantic conclusion, not a probability. Code may
compare a structurally valid, current-rubric standing with the captured minimum
standing, but must fail closed for absent, malformed, stale, or wrong-rubric
assessments. Standings must not be numerically aggregated, and raw tool
confidence must not substitute for them. This preserves #4495's configured
selection-threshold shape without inventing unsupported calibrated semantics.

## Candidate Bounded Automatic-Repair Policy

Automatic repair is an opt-in, per-run election made by an authorized user at
start. It is off by default, is never a tenant-, project-, schedule-, or
recipe-wide default, and omitted election remains entirely report-only. The
election records a minimum standing and explicit per-repair cost and time caps;
the default minimum is `supported`. The full report is delivered regardless of
which findings qualify.

On a `completed` report only, deterministic code may queue a repair through the
unchanged M04 repair pathway if all of these gates pass:

1. the captured election exists and is authorized;
2. the catalog standing is `auto_eligible` and the election does not widen it;
3. a valid assessment meets the captured minimum standing;
4. the canonical finding has no existing repair receipt for that identity;
5. the repair carries the captured cost/time caps, provenance links, and a
   scope no broader than the approved finding; and
6. the M04 checkout-revision revalidation succeeds before the recommendation
   can apply.

`partial`, `cancelled`, and `budget_exhausted` reports queue nothing and record
their non-dispatch reason. Revalidation failures are visible and never silently
dropped. Exhausted repairs preserve evidence through the base maintenance
contract. A repeated occurrence of the same canonical finding identity never
creates duplicate repair work.

`security_hardening` is `manual_only` regardless of assessment standing until a
dedicated accuracy and safety authorization changes that catalog standing.
Cost, architecture, and test-quality follow-on types begin `default_deny`;
each needs its own owner authorization and evaluation evidence before
auto-queue eligibility. A run election can narrow a catalog standing but can
never widen it.

## Delivery Mapping

| Delivery issue | Claims owned by this segment |
| --- | --- |
| #4492 | Tracking umbrella only; owns no executable claim. |
| #4493 | Catalog, menu, optional selection, snapshot, and custom-objective fallback. |
| #4494 | First recipes, scope semantics, evidence provenance, and honest coverage. |
| #4495 | Assessment standing and the opt-in bounded auto-queue gates. |
| #4496 | Security manual-only and staged follow-on recipe defaults. |

Each implementation issue remains independently blocked on base RDR-075
acceptance, M01–M04 contracts, and #4604's tool-handoff evidence. This segment
is preparation only and does not release any of those dependencies.

## Decisions & Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Type representation | Code-defined catalog with presentation menu | Run enum; project-admin authoring | Recipes can grow without schema churn while v1 keeps reviewed definitions. |
| Selection semantics | Ordered `agent_harness` standing | Calibrated numeric model confidence; raw tool confidence | Semantic judgment belongs in the agent call; neither available number is a demonstrated calibrated authorization measure. |
| Automatic repair | Per-run opt-in, completed-report-only bounded queue | Recipe default; queue from partial reports; repair in scan | Preserves the #4495 owner decision while retaining report-only investigation and fail-closed coverage. |
| Security repairs | Manual-only | Share normal auto-queue eligibility | Security changes need separate accuracy and blast-radius authorization. |

## What This Is Not

- Not acceptance of RDR-075, a feature-flag enablement, or a runtime rollout.
- Not a second repair pathway: M04 authorization, revalidation, and provenance
  remain authoritative.
- Not permission to auto-queue a security repair or any future staged type.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [maintenance-runs LLD](../maintenance-runs/maintenance-runs-design.md)
- [#4493](https://github.com/viamin/paid/issues/4493), [#4494](https://github.com/viamin/paid/issues/4494), [#4495](https://github.com/viamin/paid/issues/4495), and [#4496](https://github.com/viamin/paid/issues/4496)
- [#4636](https://github.com/viamin/paid/issues/4636) — required owner acceptance
