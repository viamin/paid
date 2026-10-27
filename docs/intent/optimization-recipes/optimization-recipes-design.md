---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipe Family

> **Draft — pending design acceptance.** Companion to
> [`docs/high-level-design.md`](../../high-level-design.md), the draft
> [`RDR-075` design](../../rdrs/RDR-075-general-maintenance-runs.md), and the
> draft [maintenance-runs LLD/EARS](../maintenance-runs/maintenance-runs-design.md)
> this segment consumes. None of those three are accepted yet, and this
> document is itself produced for the human review gate that design
> acceptance requires — it authorizes no implementation and enables no
> rollout. It fulfills [#4636](https://github.com/viamin/paid/issues/4636),
> the explicit design prerequisite for the optimization recipe family
> ([#4492](https://github.com/viamin/paid/issues/4492)–[#4496](https://github.com/viamin/paid/issues/4496)).

## Purpose

RDR-075 anticipates maintenance recipes beyond its first unnecessary-code
delivery — "dependency hygiene, stale feature flags, documentation drift, and
test quality." Optimization is the first such extension: a family of
non-functional "contracting" audits (duplication, maintainability,
performance, and later security/cost/architecture/test-quality) that make a
project more efficient without adding functionality, built entirely on the
maintenance-runs contracts rather than a parallel run type.

This segment owns three things the base maintenance LLD does not: the
optimization type catalog and menu, the three initial recipes' objective and
evidence shape, and the bounded, opt-in automatic-repair policy RDR-075
explicitly withheld ("Automatic repair is outside the initial scope and
requires a separately approved policy"). It owns none of the maintenance
run lifecycle, report/finding storage, tool attachment, or budget mechanics
themselves — those are
[`maintenance-runs`](../maintenance-runs/maintenance-runs-design.md)'s
contracts (`MAINT-*`), consumed by reference, not duplicated or
reinterpreted.

## Relationship to Base Maintenance Contracts

Every optimization run is a maintenance run (`AgentRun` goal `"maintenance"`)
with an optimization-family recipe selected. It inherits, unchanged:

- The storage contract (pinned revision, objective/scope/guidance snapshot,
  `MaintenanceReport`, canonical `MaintenanceFinding`, immutable
  `MaintenanceFindingOccurrence`) — MAINT storage contract.
- The five-value run-outcome contract (`clean`/`completed`/`partial`/
  `cancelled`/`budget_exhausted`) — no optimization-specific outcome value.
- The `maintenance_runs` rollout guard (MAINT-001–MAINT-004) — optimization
  adds no second flag.
- The RDR-073 tool-attachment/matching contract (MAINT-040–MAINT-045).
- The repair-handoff contract (MAINT-070–MAINT-073): a selected finding
  becomes a bounded issue or PR-creation run through existing authorized
  pathways.

This segment's acceptance does not require base maintenance
([#4635](https://github.com/viamin/paid/issues/4635)) to be accepted first —
the two are independent prerequisites, each reviewable on its own artifact,
per #4636's own scope statement. Implementation of #4493–#4496 still
requires both this design's acceptance **and** base maintenance's acceptance
**and** the #4604 tool-handoff evidence, because the recipes execute through
those contracts.

## Catalog and Type Menu (#4493)

The optimization family is an extensible **catalog** of recipe-backed types,
not a hard enum in the run contract. A catalog entry carries a display name,
a description of what the agent looks for, default metric hints (e.g.
latency reduction, complexity decrease, duplicated lines removed), and a
pointer to the underlying recipe definition when one exists yet.

The initial curated menu, in the order #4493/#4496 stage them, is:
Performance, Code Duplication, Maintainability / Readability (first three,
#4494); Security Hardening, Cost / Resource Efficiency, Design /
Architecture, Test Coverage & Quality (staged follow-on, #4496). A type with
no recipe yet is a valid catalog entry with no attached investigation
behavior — it exists for menu completeness, not to imply the recipe ships.

The menu is a presentation layer over the catalog: it appears wherever a
maintenance run can start (trigger-agent-run form, chat, API, MCP) with
equivalent behavior on every surface, and it composes with — never
replaces — the free-form natural-language scope field (files, a feature, a
page in the app; no scope limit by default, per MAINT-011/MAINT-014). A
project-admin catalog-authoring UI is explicitly out of scope; the catalog
is code-defined. Selecting an unmapped or custom type degrades to a
custom-objective maintenance run rather than failing, matching MAINT-044's
"fall back, never fail outright" posture for missing tool coverage. The
selected type is persisted on the run snapshot alongside objective/scope/
guidance (MAINT-015) and survives retries, exactly like any other snapshot
field.

## Recipes and Honest Evidence (#4494)

A recipe definition supplies an objective, investigation instructions,
applicable evidence collectors, validation guidance, and default metric
hints — the same shape MAINT's recipe mechanism already requires for the
unnecessary-code delivery; optimization adds entries, not a second recipe
format.

1. **Code Duplication** — tool-assisted (cross-language duplication
   detection; Ruby-specific structural/duplication analyzers where
   applicable). Carries RDR-075's own caution forward unchanged: similarity
   alone does not establish that code should be shared, and a finding must
   not recommend consolidation or deletion solely from analyzer output when
   deliberate independence or framework/dynamic-dispatch behavior is present
   (RDR-075 validation scenario 3; MAINT storage contract's finding-identity
   cautions).
2. **Maintainability / Readability** — tool-assisted where a complexity
   analyzer attaches, agent-assessed otherwise. Reports cognitive-complexity
   regressions, overly complex functions, and naming/documentation gaps as
   findings with a proposed action, not a blocking score.
3. **Performance** — prompt-first by design, with no blocking analyzer
   dependency: agent investigation of hot paths, algorithmic improvements,
   and N+1/IO patterns within scope, recording metric hints on findings.
   Tool-assisted profiling can extend this recipe later without a contract
   change (it is additive evidence, not a new finding shape).

Every optimization finding occurrence follows MAINT-025's occurrence
contract unchanged — category, affected locations/symbols, claim, supporting
evidence, known counterevidence, proposed action, validation plan, and a
verification disposition kept distinct from any raw tool-confidence score.
A repeated scan updates the same canonical finding's occurrence history per
MAINT-026/MAINT-027 rather than duplicating repair work. A clean scan (no
findings, full coverage) is a successful `clean` outcome exactly as MAINT-022
defines it; a recipe with no attached tool for a given repository falls back
to prompt-only investigation per MAINT-044, with that fallback disclosed
honestly in the report rather than silently narrowed.

## Bounded Automatic Repair Policy (#4495)

RDR-075 withholds automatic repair pending "a separately approved policy."
#4495 recorded the product owner's decisions for the optimization family
specifically (2026-10-16); this section reconciles those decisions into the
base maintenance contracts and into Zero Framework Cognition, without
inventing any further product choice. Every decision below is #4495's,
reinterpreted only where its literal wording ("confidence threshold") would
otherwise require code to invent calibrated numerical meaning.

- **Opt-in, off by default, per run.** Auto-queue is elected explicitly at
  run start (trigger form + API/MCP), never a tenant-wide, project-wide, or
  recipe-level default. Omitting the election behaves exactly like a
  report-only run — this is not a separate code path, it is simply the
  default value of one run-start field.
- **Selection signal is a semantic verification disposition, not a
  code-computed score.** #4495 names "confidence threshold" as the
  selection mechanism. Zero Framework Cognition reserves semantic judgment
  for `agent_harness` and keeps code to structural checks and policy
  enforcement (budgets, rate limits, authorization) — a numeric confidence
  score invented and thresholded in application code would be false
  precision with no rubric or evaluation corpus behind it, unlike the
  purpose-built, separately governed facet-confidence scoring (RDR-070).
  MAINT-025 already requires a "verification disposition distinct from any
  raw tool-confidence score" on every finding occurrence; this policy reuses
  that existing, already-semantic disposition rather than adding a second
  scoring concept. `agent_harness` returns the disposition through a
  structured response schema (a small ordered set of qualitative bands, not
  a float); the dispatch gate is a deterministic, ordinal comparison of that
  returned disposition against a project-configured minimum qualifying
  disposition. Nothing in this policy computes, averages, or recalibrates a
  number — it compares an agent-asserted qualitative judgment against an
  operator-set bar, which is exactly ZFC's "policy enforcement in code,
  semantic judgment in the AI call" split.
- **The full report is unaffected.** Findings below the configured bar
  remain in the report for manual selection; auto-queue only pre-selects,
  it never hides or demotes a finding.
- **Explicit budget caps per repair run.** Each auto-queued repair run
  carries its own cost/time limits, distinct from the originating
  maintenance run's budget. Exhaustion preserves collected evidence exactly
  as MAINT-024 requires for any run.
- **Revalidation is never bypassed.** An auto-queued repair goes through the
  same MAINT-071 revalidation as a manually selected one when the target
  revision has moved. Stale evidence can never silently authorize a repair,
  auto-queued or not — "automatic" describes the queuing decision, not the
  repair's authorization to apply.
- **Scope stays bounded.** Repair scope is bounded to the approved finding;
  anything broader requires the same explicit human authorization MAINT-070
  already requires for any repair handoff.
- **Idempotent by canonical identity.** A canonical finding that already has
  an active or completed repair link (MAINT-026/MAINT-027 identity) is never
  queued a second time, regardless of how many scans reproduce its
  occurrence.
- **Security is manual-only until a dedicated review.** Security-category
  findings are excluded from auto-queue unconditionally — a default-deny
  that does not depend on disposition or threshold — until a separately
  authorized accuracy/blast-radius review changes it. This exclusion is
  this document's own claim, not deferred to #4496; #4496's Security
  Hardening recipe (when it ships) inherits an exclusion that already
  exists, rather than needing its own.
- **Dispatch reuses existing authorization, not a new actor.** The user who
  elected auto-queue at run start already carries the project-scoped
  authorization MAINT-018 requires for repair selection; dispatch at report
  completion does not require a second authorization check against a
  different actor.

## Staged Follow-on Types (#4496)

Security Hardening, Cost / Resource Efficiency, Design / Architecture, and
Test Coverage & Quality register through the same catalog (#4493) with no
enum or migration work, and their recipes follow the same objective/
instructions/evidence-collector/validation-guidance/metric-hint shape as
#4494's three. This document fixes only what #4496 itself already fixed:
Security Hardening findings are report-only with manual-only repair
selection (the exclusion above), and the Test Coverage & Quality recipe
must reconcile with RDR-075's own stated future "test quality" recipe
rather than duplicate it when that recipe is designed. No other claim about
the four staged types is made here; their recipe content is evidence this
document does not have yet and is #4496's own deliverable.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Optimization as a recipe family vs. a new run type | New catalog entries + recipes on the existing maintenance `AgentRun` goal | A dedicated `"optimization"` goal | A new goal would duplicate the entire storage/outcome/tool contract MAINT already owns for no behavioral gain (RDR-075's own "new run type vs. custom prompt" reasoning applies again one level down). |
| Repair-queue selection signal | Agent-returned structured verification disposition (ordered qualitative bands) compared against a project-configured minimum qualifying disposition, via a deterministic ordinal comparison | A numeric confidence score computed and thresholded in application code; always-manual selection (reject #4495's auto-queue decision outright) | ZFC reserves semantic judgment for `agent_harness`; inventing a calibrated score in code has no rubric or evaluation corpus behind it (unlike facet-confidence's separately governed RDR-070 scoring), while MAINT-025's verification disposition already exists as the agent's assessed judgment distinct from raw tool confidence. This preserves #4495's opt-in/off-default/budget/revalidation/idempotency decisions unchanged and reinterprets only the word "threshold." |
| Security auto-queue exclusion | Unconditional default-deny, independent of disposition/threshold, until a dedicated policy review | Apply the same disposition threshold to security findings as other categories | #4495 and #4496 both already state security repairs stay manual-only; a disposition-based exclusion would let a high-confidence security finding bypass a review RDR-075's base policy explicitly reserves for later authorization. |
| Catalog authoring | Code-defined catalog entries, no project-admin authoring UI in v1 | Project-level custom-type authoring | #4493 explicitly scopes v1 to a code-defined catalog; authoring UI is unscoped future work, not a silent scope expansion here. |

## Open Questions & Future Decisions

### Resolved

1. ✅ The "confidence threshold" language in #4495 maps to MAINT-025's
   existing verification disposition plus a deterministic ordinal gate, not
   a new numeric scoring mechanism (see Decisions table).
2. ✅ Security-category auto-queue exclusion is unconditional, not
   disposition-dependent (#4495, #4496, reconciled above).

### Deferred

1. The exact structured-response schema (band labels, cardinality) for the
   verification disposition `agent_harness` returns at auto-queue
   evaluation — this is an implementation-time `agent_harness` prompt/schema
   decision for #4495's implementation, not a product policy choice; it must
   reuse MAINT-025's disposition concept rather than define a competing one.
2. The default minimum qualifying disposition and whether it is
   project-configurable or a fixed Paid-wide default — #4495's implementation
   decides this against real evaluation evidence, the same way MAINT-075's
   analyzer defaults are deferred to #4330.
3. Recipe content, evidence collectors, and metric hints for the four staged
   follow-on types — #4496's own deliverable, not fixed here.
4. Whether `ScheduledMutationSweepJob`/`MutationSweeps::Run` could become an
   optimization recipe — inherits MAINT's own open question; no migration is
   designed here.

## What This Is Not

- Not a second run type, report schema, or finding-identity model — every
  optimization run is a maintenance run using MAINT's unchanged contracts.
- Not a numeric confidence-scoring system — it reuses MAINT-025's qualitative
  verification disposition and a deterministic ordinal gate; it does not
  introduce calibrated probabilities, an evaluation corpus, or tunable
  thresholds in the sense RDR-070/facet-confidence defines them.
- Not a rollout of automatic repair — this document is docs-only, accepts no
  runtime change, and keeps the `maintenance_runs` guard and RDR-073's tool
  guard as the only admission controls. Acceptance of this design is not
  activation of auto-queue.
- Not permission to skip LID review of #4493–#4496 — this document narrows
  their remaining design freedom; each still needs its own failing-first
  tests and implementation review against the contracts fixed here.

## Traceability

- [#4492](https://github.com/viamin/paid/issues/4492) is a **tracking
  umbrella** (labeled `epic`, excluded from auto-pick) — it coordinates and
  audits the family's final acceptance; it is not an executable deliverable
  and this document fixes no claim solely for #4492's sake.
- [#4493](https://github.com/viamin/paid/issues/4493) — Catalog and Type
  Menu section above.
- [#4494](https://github.com/viamin/paid/issues/4494) — Recipes and Honest
  Evidence section above.
- [#4495](https://github.com/viamin/paid/issues/4495) — Bounded Automatic
  Repair Policy section above.
- [#4496](https://github.com/viamin/paid/issues/4496) — Staged Follow-on
  Types section above (intentionally minimal: #4496 owns its own recipe
  content).

## Rollout Guard

Docs-only: this document and its EARS specs ship no runtime behavior. When
#4493–#4496 implement against this contract, they ride the existing
`maintenance_runs` tenant rollout guard (MAINT-001–MAINT-004) and RDR-073's
own tool guard; this segment defines no second flag. Auto-queue
(#4495/MAINT-OPT-030–MAINT-OPT-043) is additionally gated by its own
per-run, off-by-default election — disabling `maintenance_runs` stops new
auto-queue dispatch the same way it stops any new maintenance admission,
without cancelling an active repair run or deleting an existing report.

## References

- [RDR-075 draft](../../rdrs/RDR-075-general-maintenance-runs.md)
- [maintenance-runs LLD](../maintenance-runs/maintenance-runs-design.md) and
  [its EARS](../maintenance-runs/maintenance-runs-specs.md) — the base
  contract this segment consumes throughout
- [facet-confidence LLD](../facet-confidence/facet-confidence-design.md) —
  precedent for "agent judgment, deterministic enforcement" and for keeping
  calibrated numeric scoring inside its own separately governed rubric
  rather than ad hoc per-feature thresholds
- [#4492](https://github.com/viamin/paid/issues/4492),
  [#4493](https://github.com/viamin/paid/issues/4493),
  [#4494](https://github.com/viamin/paid/issues/4494),
  [#4495](https://github.com/viamin/paid/issues/4495),
  [#4496](https://github.com/viamin/paid/issues/4496)
- [#4636](https://github.com/viamin/paid/issues/4636) — this design's own
  issue; [#4635](https://github.com/viamin/paid/issues/4635) — the
  independent base-maintenance acceptance prerequisite
