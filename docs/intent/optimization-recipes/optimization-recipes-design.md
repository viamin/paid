---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Maintenance Optimization Recipes

> **Draft — pending design acceptance.** Companion to the draft base
> maintenance contracts
> ([`maintenance-runs-design.md`](../maintenance-runs/maintenance-runs-design.md))
> and, through them, to draft
> [`RDR-075`](../../rdrs/RDR-075-general-maintenance-runs.md) (still
> Status: Draft). This LLD and its EARS specs are reviewable contracts
> produced for the design prerequisite tracked by
> [#4636](https://github.com/viamin/paid/issues/4636); they reconcile the
> owner decisions already recorded in
> [#4495](https://github.com/viamin/paid/issues/4495) (agreed 2026-10-16)
> with the base maintenance contracts. They are not accepted intent, they
> authorize no implementation, and merging them enables no rollout: the
> optimization family's runtime work stays blocked on base maintenance
> design acceptance
> ([#4635](https://github.com/viamin/paid/issues/4635)) and on the base
> milestones M01–M04
> ([#4328](https://github.com/viamin/paid/issues/4328)–[#4331](https://github.com/viamin/paid/issues/4331)).

## Purpose

The optimization recipe family extends the planned general maintenance
capability with non-functional **contracting audits**: investigations that
make a project more efficient without adding functionality. A project owner
selects an optimization type from a code-defined catalog — or describes one
in free text — optionally bounds the investigation with a free-form
natural-language scope, and receives the same honest, evidence-backed
report every maintenance run produces. The owner may also, only through an
explicit per-run election made at start, pre-authorize **bounded repair
runs** to be queued automatically once the report completes.

RDR-075 states: "Automatic repair is outside the initial scope and requires
a separately approved policy." The auto-queue contract below is that
policy, drafted for review — opt-in, off by default, and gated on the base
repair-handoff pathways. Nothing here silently authorizes runtime repair
behavior.

This LLD owns the catalog/type-selection contract, the optimization recipe
content policy, the staging policy for follow-on types, and the bounded
auto-queue selection policy. It owns no new run lifecycle, report, finding,
schedule, or repair machinery: all of that is the base maintenance
contracts, consumed unchanged. Tool attachment and matching remain RDR-073
territory.

## Segment placement

This is a leaf segment whose EARS prefix `MAINT-OPT` deliberately extends
the base `MAINT` path: a prefix-grep for `MAINT` gathers the entire
maintenance subtree, and `MAINT-OPT` gathers this family alone. The base
`maintenance-runs` leaf keeps its own specs untouched; no sub-HLD promotion
is warranted because the shared parent intent (maintenance investigations
with honest reports and bounded repair) already lives in the base LLD.

## Catalog Contract

The optimization type catalog is **code-defined**: a set of catalog
entries, not an enum value, a migration, or a run-contract change. Each
entry carries a key, display name, description of what the investigation
looks for, default metric hints (e.g. latency reduction, complexity
decrease, duplicated lines removed), and a pointer to the underlying recipe
definition when one exists. Adding a type is a catalog entry only. There is
no project-admin authoring UI in v1; the catalog is reviewable as code.

The initial curated list has seven types: Performance, Design /
Architecture, Code Duplication, Security Hardening, Cost / Resource
Efficiency, Maintainability / Readability, and Test Coverage & Quality. The
curated type menu is presentation over the catalog — surfaced wherever
maintenance runs are started (run-trigger form and chat), with equivalent
project-scoped start authorization on the UI, API, and MCP surfaces. Runs
stay startable without a type selection; the base admission rule
(MAINT-011: recipe objective or nonblank guidance) is unchanged.

Type selection is part of the run snapshot: recorded at start alongside
objective, scope, and guidance, immutable after start, and retained across
retries (MAINT-015). An unmapped type value degrades to a custom-objective
maintenance run that retains the selection verbatim as context — never an
error — and the base admission rule still applies to the degraded run.

Where a surface accepts natural-language input (chat), resolving a user
description to a catalog type is a semantic judgment: it goes through an
`agent_harness` call returning a structured candidate type with cited
reasons (or none), never keyword, regex, or other code-side text matching.
Deterministic code validates that a resolved candidate exists in the
catalog and records the user's verbatim input; a failed resolution leaves
the run startable as a custom-objective investigation.

## Recipe Contract

A recipe definition supplies the objective, investigation instructions,
applicable evidence collectors, validation guidance, and default metric
hints from its catalog entry. The first three recipes are chosen for a mix
of ready tool evidence and prompt-first value:

1. **Code Duplication** — tool-assisted where analyzers attach (PMD CPD
   for cross-language duplication; Exhale/Debride-class analyzers for Ruby
   where applicable).
2. **Maintainability / Readability** — complexity evidence where
   available, agent-assessed; cognitive-complexity regressions, overly
   complex functions, and naming/doc gaps as reportable findings with
   proposed actions.
3. **Performance** — prompt-first initially, with no blocking analyzer
   dependency: investigation of hot paths, algorithmic improvements, and
   N+1/IO patterns within scope, with metric hints recorded on findings.
   Tool-assisted profiling can extend the recipe later without contract
   changes.

Honest evidence rides the base contracts, not a family-specific copy:
report outcomes and per-occurrence evidence per MAINT-020–MAINT-029, tool
invocation and provenance per MAINT-040–MAINT-043, and the prompt-only
fallback per MAINT-044. A performance run with no planned tool check that
completes with no findings reports `clean`; a planned tool check that
fails still forces `partial` (MAINT-022). Prompt-first paths record
prompt-only evidence honestly.

The RDR-075 false-positive cautions are binding recipe policy, not
guidance. Tool output identifies candidates; it never settles a
disposition. Similarity alone does not establish that code should be
shared; absence of static references does not establish that code can be
deleted. Deliberate independence, framework callbacks, reflection,
external APIs, and compatibility obligations must be considered. A
finding's verification disposition (MAINT-025) is settled by a semantic
assessment through `agent_harness` against the finding's cited supporting
evidence and counterevidence — analyzer output alone is never sufficient.

### Scope

Optimization scope is free-form natural language composed with the
selected type: files, a feature, or a page in the app are all valid, and
no breadth limit is imposed by default. That is the family's "broad
recommendation scope": breadth is admitted and recorded, not restricted.
The base scope contracts still govern — named targets resolve before
coverage is claimed (MAINT-012), ambiguous or missing targets produce an
actionable clarification outcome rather than a silent repository-wide scan
(MAINT-013), and an absent scope is recorded as an explicit broad-scope
investigation (MAINT-014).

Scope bounds recommendations, not access to supporting evidence (RDR-075):
callers, tests, framework entry points, and design documents elsewhere in
the repository may be inspected to validate a claim. Any recommendation
requiring changes beyond the requested scope must identify that expansion
explicitly, and acting on it requires separate authorization.

### Staged follow-on types

Security Hardening, Cost / Resource Efficiency, Design / Architecture, and
Test Coverage & Quality register through the same catalog contract, staged
after the first three recipes prove the contracts: each stage lands only
when its predecessors' evaluation evidence supports it. Two staging rules
are contract, not sequencing preference:

- **Security findings are report-only with manual repair selection.** They
  are excluded from auto-queue by default and stay excluded until a
  dedicated accuracy and blast-radius review lands a separately accepted
  policy authorizing them.
- **Test Coverage & Quality is one recipe**, reconciled with the base
  maintenance capability's anticipated test-quality recipe (RDR-075
  "Future recipes"), not a duplicate optimization-specific recipe.

Where a staged type has no credible tool-evidence path, it lands
prompt-first and records that honestly in its reports. Per-recipe
evaluation evidence on at least one non-Paid project is recorded before a
stage is considered proven; that evidence guides later staging and any
future blocking-policy decisions, not the existence of the capability.

## Bounded Auto-Queue Policy

This section is the separately approved automatic-repair policy RDR-075
requires, drafted for review. The owner decisions recorded in #4495
(2026-10-16) are preserved exactly; the Decisions & Alternatives table
records them with their alternatives. The policy remains off by default
and authorizes nothing until this LLD/EARS pair is accepted and the base
maintenance contracts are implemented and accepted.

### Election

Auto-queue is a **per-run election at start only**, surfaced on the
run-trigger form, API, and MCP with equivalent authorization, with
confidence-threshold and budget defaults visible at election time. It is
never enabled tenant-wide, never a recipe or schedule default, and never
electable after a run has started. An omitted election behaves exactly as
a report-only base maintenance run. The election is captured immutably in
the run snapshot: the chosen confidence threshold and explicit
per-repair-run cost/time budget caps.

### Selection gate

When a report completes with an election in effect, a finding is queued
only if every deterministic gate passes. The gates run in code —
authorization, category eligibility, idempotency, and budgets are
structural checks, not judgments:

1. **Admission recheck**: the `maintenance_runs` guard is enabled and the
   election is valid at dispatch time; guard disable stops new auto-queues
   without cancelling already-active repair runs or deleting reports.
2. **Category eligibility**: the finding's category is auto-queue-eligible;
   security-category findings are default-deny.
3. **Confidence**: the finding's assessed selection confidence meets or
   exceeds the elected threshold.
4. **Idempotency**: no repair work is already queued, active, or completed
   for the same canonical finding identity (MAINT-026/MAINT-027); repeated
   occurrences of a finding never queue duplicate repair work.
5. **Budget**: explicit per-repair cost/time caps are present and are
   recorded on the created repair run; exhaustion preserves collected
   evidence per MAINT-024.

### Confidence assessment and Zero Framework Cognition

The selection-confidence value is a **semantic assessment through
`agent_harness`**, made against a versioned rubric that cites the finding
occurrence's supporting evidence and counterevidence, returning a bounded
value with an explanation and source references. Code validates the
response's structure and bounds; it never computes, adjusts, or aggregates
the value, and it never derives selection confidence from raw analyzer or
tool confidence scores — those are provenance (MAINT-025, MAINT-043), not
semantics. An unknown, unavailable, malformed, or stale assessment fails
closed: the finding is not queued, remains manually selectable, and the
assessment failure is visible in the report — never silently dropped.

This reconciles the threshold policy with the house confidence discipline
(RDR-070 / `facet-confidence`, `bounded-phase-authorization`): thresholds
and rubric values are provisional policy settings on a rubric-defined
evidence-strength scale, not calibrated probabilities, and selected
findings are never presented as statistically certain. Comparison is
per-finding meets-or-exceeds; there is no aggregation formula and no
averaging across findings or occurrences. The discipline is reused without
importing facet-confidence's readiness semantics: a maintenance finding is
not a feature facet, and auto-queue selection is not readiness.

### Report integrity and dispatch

The report is always delivered in full; selection affects only repair
dispatch, never report content or outcomes. Findings below threshold or
excluded by category remain visible and manually selectable (MAINT-018,
MAINT-070). Auto-queued repairs dispatch through the base repair-handoff
pathways unchanged: provenance links back to the source report and finding
identity (MAINT-072), revalidation is required when the target revision
has moved (MAINT-071), dispatch or revalidation failures surface visibly
on the queued work, and repair scope stays bounded to the selected finding
— anything broader requires explicit human authorization.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Catalog shape | Code-defined catalog entries; type menu is presentation over the catalog | Enum column with migrations; project-admin authoring UI in v1 | Adding a type must be a catalog entry only (#4493); an enum makes every type a schema event, and a v1 authoring surface moves catalog review out of code review. |
| Type selection persistence | Part of the immutable run snapshot, retained across retries | Re-resolving the type from free text on each retry | The base snapshot contract (MAINT-015) exists so retries keep context; re-resolution could change the investigated objective between attempts. |
| Natural-language type resolution | `agent_harness` structured candidate + deterministic catalog validation | Keyword/regex matching in code; forcing menu-only selection | ZFC: mapping a description to a type is semantic; code-side text matching is the named anti-pattern. Chat remains usable without the menu. |
| Auto-queue authorization model | Per-run election at start, off by default | Tenant-wide enablement; recipe defaults; post-report election | Owner decision, #4495 2026-10-16: pre-authorization is explicit and scoped to one report; tenant/recipe defaults or post-hoc election would make repair a standing side effect of investigation, which RDR-075 excludes. |
| Selection policy | Confidence threshold on agent-assessed selection confidence | First-N findings; queue everything; raw tool-confidence thresholds | Owner decision, #4495. Tool confidence is provenance, not semantics (MAINT-025); thresholds are provisional policy settings, not calibrated probabilities. |
| Gate placement | Deterministic gates in code; semantic assessment in `agent_harness` | Code-computed confidence scores; unstructured LLM yes/no | ZFC and the house pattern (RDR-070, `BOUNDED-PHASE-AUTHORIZATION-006`): code enforces authorization/budget/idempotency/bounds; `agent_harness` owns semantic judgment with structurally validated output and fail-closed handling. |
| Security handling | Default-deny from auto-queue; manual selection only | Include security at the same threshold as other types | Owner decision, #4495/#4496: hardening changes carry blast-radius risk that evidence confidence alone does not bound; a dedicated accuracy and blast-radius review must separately authorize inclusion. |
| Schedules and auto-queue | No schedule may auto-queue until separately designed and accepted | Let schedules carry the election | The recorded election is per-run at start; a standing schedule election would function as the recipe default the owner decisions exclude. Default-deny until explicitly designed. |
| Test-quality type | One recipe reconciled with the base capability's anticipated test-quality recipe | Optimization-specific duplicate recipe | #4496 requires reconciliation rather than duplication; two recipes would double-report the same findings. |
| Segment placement | Leaf with prefix `MAINT-OPT` | Facet inside the base MAINT specs; sub-HLD promotion | The family has its own issue tree and acceptance gate; the base leaf keeps its specs; `MAINT-OPT` keeps the maintenance subtree grep-coherent without restructuring artifacts owned by #4635. |

## Open Questions & Future Decisions

### Deferred

1. Exact confidence-threshold defaults, budget-cap defaults, and the rubric
   versioning scheme — provisional policy settings decided at
   implementation and evaluation (#4495), never presented as calibrated.
2. Metric-hint shape and how expected-improvement hints render in reports
   — #4493/#4494 detail, resolved with the report schema.
3. Which analyzers pair with the duplication and maintainability recipes —
   decided by M03 evidence (#4330) and #4494's per-recipe evaluation, not
   by this design.
4. The dedicated security auto-queue review's accuracy and blast-radius
   criteria — #4496's later stage; until then the default-deny exclusion
   stands.
5. Whether recurring optimization schedules may carry an auto-queue
   election for dispatched occurrences — undecided; no schedule may
   auto-queue until a separately accepted design extends the election.
6. Whether staged types adopt recipe-specific budget or threshold presets —
   no family-specific addition is anticipated beyond the base scheduling
   contract (MAINT-060–MAINT-064).

## What This Is Not

- Not an implementation authorization: every spec is an active gap `[ ]`;
  the optimization children (#4493–#4496) stay blocked on base maintenance
  acceptance (#4635) and the base milestones they already declare.
- Not a rollout enablement: everything rides the default-off
  `maintenance_runs` guard; accepting this design does not flip it, and
  RDR-073's tool guard remains separately authoritative.
- Not a second run, report, finding, schedule, or repair model: the base
  maintenance contracts are consumed unchanged.
- Not a blocking PR gate and not an automatic-repair general warrant:
  auto-queue is the narrow, opt-in, off-by-default policy above, and
  security findings stay manual-selection-only until separately
  authorized.

## Delivery Map

| Area | Specs | Delivery issue |
| --- | --- | --- |
| Catalog and type selection | MAINT-OPT-001 – MAINT-OPT-006 | [#4493](https://github.com/viamin/paid/issues/4493) (OPT-01) |
| First recipes and honest evidence | MAINT-OPT-010 – MAINT-OPT-017 | [#4494](https://github.com/viamin/paid/issues/4494) (OPT-02) |
| Staged follow-on types | MAINT-OPT-020 – MAINT-OPT-024 | [#4496](https://github.com/viamin/paid/issues/4496) (OPT-04) |
| Bounded auto-queue policy | MAINT-OPT-030 – MAINT-OPT-041 | [#4495](https://github.com/viamin/paid/issues/4495) (OPT-03) |

[#4492](https://github.com/viamin/paid/issues/4492) is the tracking
umbrella only. It is not an executable prerequisite deliverable: it closes
through its own final evidence-based coordination/acceptance audit after
its children and these design prerequisites, and no runtime authorization
follows from removing its tracking relationships.

## References

- [RDR-075 draft](../../rdrs/RDR-075-general-maintenance-runs.md) — the
  base capability this family extends
- [Base maintenance LLD](../maintenance-runs/maintenance-runs-design.md)
  and [EARS](../maintenance-runs/maintenance-runs-specs.md) — the MAINT
  contracts consumed here
- [Umbrella #4492](https://github.com/viamin/paid/issues/4492) —
  optimization recipe family epic (tracking)
- [Design prerequisite #4636](https://github.com/viamin/paid/issues/4636)
  — this artifact's acceptance gate
- [RDR-070](../../rdrs/RDR-070-facet-confidence-and-clarification.md) and
  [`facet-confidence`](../facet-confidence/facet-confidence-design.md) —
  the house confidence discipline reconciled above
- [`bounded-phase-authorization`](../bounded-phase-authorization/bounded-phase-authorization-specs.md)
  — the fail-closed `agent_harness` assessment pattern reused above
- [RDR-073](../../rdrs/RDR-073-marketplace-tool-sidecars.md) — tool
  attachment and matching, consumed via the base contracts
