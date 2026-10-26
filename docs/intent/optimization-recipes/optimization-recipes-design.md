---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Maintenance Optimization Recipes

> **Draft — pending owner acceptance.** This leaf extends the draft
> [`maintenance-runs`](../maintenance-runs/maintenance-runs-design.md) segment
> and [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md). It is a
> documentation-only preparation for [#4636](https://github.com/viamin/paid/issues/4636): it authorizes neither implementation nor rollout.

## Purpose

Optimization recipes let a project owner request a report-only investigation
of non-functional improvements without adding a new maintenance run type. The
catalog provides a curated starting point while preserving a user-directed,
free-text question. Findings remain evidence-backed recommendations, not
authority to mutate source code.

This segment owns the optimization catalog, its recipe content, semantic
assessment contract, and the narrowly proposed auto-queue policy. It consumes
the base maintenance lifecycle, reports, finding identity, repair handoff,
tenant guard, authorization, and RDR-073 tool attachment contracts. It does
not own a second catalog, a new guard, a new repair pathway, or base-maintenance
acceptance.

## Catalog and Scope

The initial catalog has seven code-defined entries: Code Duplication,
Maintainability / Readability, Performance, Security Hardening, Cost / Resource
Efficiency, Design / Architecture, and Test Coverage & Quality. An entry
declares display text, investigation instructions, applicable evidence
collectors, validation guidance, default metric hints, and its repair standing.
Adding a type is a catalog/recipe change, not an enum or migration. An unknown
selection becomes the existing custom-objective path rather than failing a
start request.

The UI, API, and MCP expose the same authorized choice and persist it in the
immutable run snapshot with objective, scope, guidance, recipe version, and
tool configuration. A scope may be named paths or symbols, or a free-text
natural-language target such as a feature or page. It bounds recommendations,
not access to supporting evidence: the investigation may inspect callers,
tests, framework entry points, and design documents to validate a claim. Any
recommendation outside the stated scope explains that expansion; repair scope
still needs explicit authorization.

## Recipe Evidence and Assessment

The first delivery recipes are Code Duplication, Maintainability / Readability,
and Performance. Duplication and maintainability may use applicable RDR-073
evidence collectors; Performance is prompt-first until credible profiling
evidence is integrated. A recipe without an attached tool records prompt-only
coverage rather than claiming tool coverage. Tool output is candidate evidence,
not proof: similarity, missing static references, or absent test coverage alone
does not establish that consolidation or deletion is safe.

Every finding retains the base occurrence contract: claim, locations/symbols,
supporting evidence, counterevidence, proposed action, validation plan,
provenance, and verification disposition. A completed report distinguishes
actionable findings, unresolved candidates, deliberate exceptions, and coverage
limits. An unavailable or failed planned check remains partial; an absent
applicable tool can still yield an honestly reported prompt-only investigation.

`agent_harness` performs semantic assessment using a versioned structured
rubric and cited evidence. The result has an ordered eligibility standing:
`supported`, `marginal`, `unsupported`, or `unknown`, plus an explanation and
evidence references. These are qualitative rubric outputs, not calibrated
probabilities; no numeric meaning is invented or aggregated. Code structurally
validates the response and fails closed on a missing, malformed, stale, or
`unknown` assessment. Raw analyzer confidence never drives repair eligibility.
This division preserves Zero Framework Cognition: the agent judges meaning;
code controls I/O, policy, state, and limits.

## Bounded Auto-Queue Policy

Base maintenance remains report-only. The proposed exception is an explicit,
per-run election at start, off by default, for optimization findings only. It
records a minimum eligibility standing and explicit per-repair cost and time
caps; omission has exactly the base report-only behavior. The full report is
always delivered, including findings that do not qualify. Schedules cannot
elect auto-queue because a standing schedule choice would be a recipe default;
they remain default-deny pending a separately approved design.

After a `completed` report only, the deterministic dispatcher may use the
existing M04 repair pathway when all gates pass: the election is present and
authorized, the finding meets the configured standing, its catalog repair
standing permits auto-queue, a bounded budget is present, and no repair exists
for the canonical finding identity. The default minimum is `supported`.
`partial`, `cancelled`, and `budget_exhausted` reports queue nothing and record
why. A repair retains source-report and finding provenance, has its own budget,
and preserves collected evidence if exhausted.

The existing repair pathway revalidates evidence against a changed repair
checkout before applying a recommendation. A failed or unavailable
revalidation remains visible and creates no silent repair. Scope is bounded to
the approved finding; expansion requires a human authorization. Idempotency is
keyed to the canonical project/recipe/claim/affected-symbol finding identity,
not an occurrence or report, so repeated scans cannot enqueue duplicate work.

The election can only narrow catalog authority. Security Hardening is
`manual_only`: it is reportable and manually selectable, but never auto-queued
until a dedicated accuracy and safety review is accepted. Cost / Resource
Efficiency, Design / Architecture, and Test Coverage & Quality are
`default_deny` until separate owner authorization with evaluation evidence.
Only the first three recipe types may be considered for the proposed policy.

## Delivery Mapping

| Claim area | Delivery owner | Boundary |
| --- | --- | --- |
| Catalog, menu, custom fallback, immutable selection snapshot | [#4493](https://github.com/viamin/paid/issues/4493) | Executable prerequisite; reuses M01. |
| First recipes, evidence and honest report coverage | [#4494](https://github.com/viamin/paid/issues/4494) | Executable prerequisite; reuses M02/M03. |
| Per-run election and bounded auto-queue gates | [#4495](https://github.com/viamin/paid/issues/4495) | Executable prerequisite; reuses M04. |
| Staged types, including manual-only security | [#4496](https://github.com/viamin/paid/issues/4496) | Executable follow-on; no auto-queue authority. |
| Family coordination | [#4492](https://github.com/viamin/paid/issues/4492) | Tracking umbrella only; not an implementation prerequisite. |

All executable issues remain independently blocked on accepted base maintenance
intent, the `maintenance_runs` default-off guard, and their declared RDR-073
and maintenance dependencies. Acceptance of this draft does not remove those
blocks or enable runtime behavior.

## Decisions & Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Catalog representation | Code-defined recipe entries | Enum/migration; a second tool catalog | Recipes need extensibility without duplicating RDR-073. |
| Eligibility signal | Agent rubric standing | Raw tool confidence; calibrated application probability | Semantic judgment belongs in `agent_harness`; no calibration evidence supports a numeric gate. |
| Auto-queue default | Per-run opt-in, off | Tenant or recipe default | Preserves report-only maintenance and a revocable, explicit authorization. |
| Auto-queue identity | Canonical finding identity | Report or occurrence identity | Recurring occurrences must not create duplicate repair work. |
| Security repairs | Manual-only | Threshold-based auto-queue | Security changes need a separate safety and accuracy authorization. |

## Open Decision for Owner Acceptance

The owner must accept or amend this draft as one package: the qualitative
standing threshold and `supported` default; completed-report-only dispatch;
election-only-narrows; manual-only security; default-deny staged types;
canonical-finding idempotency; and free-text scope as a recommendation bound.
Until the accepted artifacts merge, [#4636](https://github.com/viamin/paid/issues/4636)
remains open with this concrete Inbox decision and no implementation proceeds.

## What This Is Not

- Not acceptance of RDR-075, the maintenance implementation, or rollout.
- Not an automatic source mutation or a replacement for M04 repair authorization.
- Not an authorization for Security Hardening repairs to auto-queue.
- Not a closing artifact for [#4492](https://github.com/viamin/paid/issues/4492).
