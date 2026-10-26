---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipe Family and Bounded Automatic Repair

> **Draft — pending owner acceptance.** Companion to
> [`docs/high-level-design.md`](../../high-level-design.md), the draft
> [`RDR-075`](../../rdrs/RDR-075-general-maintenance-runs.md) design, and the
> base [`maintenance-runs`](../maintenance-runs/maintenance-runs-design.md)
> LLD/EARS pair. This segment records the owner decisions recorded in
> [#4495](https://github.com/viamin/paid/issues/4495) as reviewable intent and
> authorizes no runtime behavior: the family ships only behind the base
> `maintenance_runs` guard, and automatic repair remains off unless a user
> elects it for one run. Acceptance of these exact revisions is a human
> action tracked by [#4636](https://github.com/viamin/paid/issues/4636); the
> base maintenance acceptance tracked by
> [#4635](https://github.com/viamin/paid/issues/4635) remains an independent
> prerequisite of the implementation issues.

## Purpose

A project owner can already ask Paid to investigate repository health through
a maintenance run. The **optimization family** adds a curated, extensible set
of *non-functional* audit types to that capability — performance, design and
architecture, code duplication, security hardening, cost and resource
efficiency, maintainability and readability, test coverage and quality — so
the owner can ask "make this project cheaper/faster/cleaner" instead of
formulating the investigation from scratch.

The family exists because those questions share one shape and one risk. They
are answered by evidence that is easy to overstate: an analyzer's similarity
score is not a consolidation decision, a hotspot hypothesis is not a measured
latency win, and a security finding is not a safe automatic edit. The family
therefore fixes three things and refuses to invent a fourth:

1. **A catalog, not an enum.** Optimization types are code-defined catalog
   entries surfaced as a menu; a new type is a catalog entry, never a
   migration or an authoring surface.
2. **Honest evidence.** Tool evidence and agent assessment stay separate, and
   a run that could not complete a planned check says so instead of reporting
   a clean result.
3. **A bounded, elected repair path.** Repair work stays separate from the
   investigation. It is either selected manually from the report, or queued
   automatically only when the user elected that policy **at run start**,
   under deterministic authorization, budget, idempotency, and revalidation
   gates.

## Canonical EARS prefix

This segment allocates **`MAINT-OPT`** for the optimization family. It is a
sibling leaf of `maintenance-runs` (`MAINT`), not a facet of it: the base
maintenance contracts — run goal, report outcome, canonical finding identity,
occurrence records, repair handoff — are consumed rather than restated, and
the family adds its own claims. The prefix extends `MAINT` so that a `MAINT`
prefix-grep still gathers both leaves, following the same sibling-prefix
pattern the `FREE-MODEL`, `FREE-MODEL-RUNNER`, and `FREE-MODEL-SYNC` leaves
already use.

## Boundary

| Owned here | Consumed, not duplicated |
| --- | --- |
| Optimization type catalog and its curated type menu | Base maintenance run goal, snapshot fields, report outcomes, canonical finding identity, occurrence records, manual repair handoff (`MAINT`) |
| Optimization recipe definitions and their honest coverage | RDR-073 marketplace attachment, matching, provisioning, sidecar lifecycle (`marketplace-tool-sidecars`) |
| Optimization scope semantics (natural-language scope, resolution, broad-scope recording) | Base scope contract and clarification outcomes (`MAINT-011`–`MAINT-014`) |
| The run-start automatic-repair election and its gates | Base rollout guard `maintenance_runs` (`MAINT-001`–`MAINT-004`) |
| Repair-eligibility assessment contract | `agent_harness` as the only application-level LLM interface |

This segment defines no new run goal, no new report or finding model, no new
feature flag, and no new tool catalog. An optimization investigation is a
maintenance run whose recipe family is `optimization`
(`MAINT-OPT-003`, `MAINT-OPT-006`).

### Base reconciliation

Two base claims are reconciled here rather than restated in this segment, and
both edits live in the base segment's specs and design so that a reader of
either leaf sees one source of truth:

| Base claim | Reconciliation |
| --- | --- |
| `MAINT-011` — the accepted scope form | Widened from "paths or symbols" to name a free-text description of the area under investigation as well, and to defer the per-family forms to this segment's design (`MAINT-OPT-030`). |
| `MAINT-073` — repair work needs an explicit user selection | Widened to name the run-start election of a bounded automatic-repair policy as one such recorded selection, while keeping the base default report-only (`MAINT-OPT-040`). |

No other base claim changes, and the base segment's admission, report,
finding, schedule, and tool-integration contracts are unaffected by this
family.

## Recipe catalog

### Catalog entries

A catalog entry is code-defined and carries:

| Field | Meaning |
| --- | --- |
| `key` | Stable, machine-readable identifier recorded on the run snapshot. |
| `display_name` | The label a user reads in the menu. |
| `description` | What the agent looks for; the seed for a custom objective when no packaged recipe exists. |
| `metric_hints` | Default hints (for example "duplicated lines removed") attached to findings as hints, never as measured values (`MAINT-OPT-023`). |
| `recipe_definition` | Pointer to the packaged recipe, when one is available. |
| `delivery_stage` | `first` (the first three recipes) or `staged` (the follow-on types). |
| `automatic_repair_standing` | `eligible`, `default_deny`, or `manual_only`. |

### Curated types

The catalog ships with the seven curated types. Their standing follows the
owner decisions in
[#4495](https://github.com/viamin/paid/issues/4495) and
[#4496](https://github.com/viamin/paid/issues/4496): the first three recipes
are auto-repair eligible subject to the run-start election, security
hardening is manual-only until a dedicated policy review, and the remaining
staged types are default-deny until separately authorized.

| Type | Stage | Automatic-repair standing | Recipe lands in |
| --- | --- | --- | --- |
| Code Duplication | first | eligible | [#4494](https://github.com/viamin/paid/issues/4494) |
| Maintainability / Readability | first | eligible | [#4494](https://github.com/viamin/paid/issues/4494) |
| Performance | first | eligible | [#4494](https://github.com/viamin/paid/issues/4494) |
| Security Hardening | staged | manual_only | [#4496](https://github.com/viamin/paid/issues/4496) |
| Cost / Resource Efficiency | staged | default_deny | [#4496](https://github.com/viamin/paid/issues/4496) |
| Design / Architecture | staged | default_deny | [#4496](https://github.com/viamin/paid/issues/4496) |
| Test Coverage & Quality | staged | default_deny | [#4496](https://github.com/viamin/paid/issues/4496) |

### Extensibility and degradation

Adding a type is a catalog entry (`MAINT-OPT-012`). There is no
project-admin authoring UI in the first delivery and no schema change. A
submitted type value that matches no entry degrades to a custom-objective run
rather than failing (`MAINT-OPT-015`), and a catalog entry whose packaged
recipe is not yet available degrades the same way, with the report disclosing
that no packaged recipe backed the investigation
(`MAINT-OPT-016`). Neither degradation may claim recipe-backed coverage.

## Scope semantics

Optimization scope accepts three forms: paths, symbols, and free-text
natural language naming an area under investigation — a file set, a feature,
or a page (`MAINT-OPT-030`). The free-text form is the family's addition to
the base scope contract, which is why `MAINT-011` now names the accepted
scope forms and defers the per-family detail here.

Scope keeps the base meaning: it bounds the recommendations a run may make,
not the evidence it may inspect (`MAINT-OPT-034`). A run may read callers,
tests, framework entry points, and design documents outside the requested
scope to validate a claim; a recommendation that requires changes beyond the
resolved scope requires explicit human authorization before any repair
applies.

Resolution of a requested scope is a **semantic** judgment, so it is performed
through `agent_harness` with a structured response (`MAINT-OPT-031`). An
ambiguous or missing target produces an actionable clarification outcome, not
a silent broadening (`MAINT-OPT-032`). A run with no scope is an explicit
broad-scope investigation; the family imposes no default scope limit
(`MAINT-OPT-033`). The requested scope, the resolved scope, and any exclusions
are recorded separately (`MAINT-OPT-035`).

## Honest evidence

A recipe definition supplies an objective, investigation instructions,
applicable evidence collectors, validation guidance, and default metric hints
(`MAINT-OPT-020`). Execution reuses the base tool contract: RDR-073
attachments for tool-assisted evidence, native CLI analyzers through
`AgentRun#execute_in_execution_environment` once
[#4604](https://github.com/viamin/paid/issues/4604) has recorded the live
execution-environment evidence, and a prompt-only path where no applicable
tool exists (`MAINT-OPT-022`).

Three honesty rules are specific to this family:

- **Tool confidence is not assessment.** A raw analyzer score is provenance
  (`MAINT-OPT-021`), never the agent's verification disposition and never a
  selection threshold input (`MAINT-OPT-056`).
- **Metric hints are hints.** A hint such as "duplicated lines removed" is
  attached to a finding as a hypothesis; it is never presented as a measured
  value or a calibrated improvement estimate (`MAINT-OPT-023`).
- **Duplication is a claim, not a verdict.** A duplication finding may not
  recommend consolidation or deletion on similarity alone; the assessment
  must consider deliberate independence, framework callbacks, reflection,
  external APIs, and compatibility obligations (`MAINT-OPT-024`). A
  performance finding may not present an unmeasured hypothesis as a measured
  latency or cost reduction (`MAINT-OPT-025`).

Incomplete coverage stays incomplete: a planned check that did not complete
forces the base `partial` outcome and names the checks that did not run
(`MAINT-OPT-026`). Provenance is comparable across repeated scans because each
run records its packaged recipe version and its catalog-entry version
(`MAINT-OPT-027`).

## Semantic assessment

Every semantic judgment in this family is an `agent_harness` call with a
structured response schema (`MAINT-OPT-050`):

| Judgment | Input | Output shape |
| --- | --- | --- |
| Scope resolution | requested scope, repository evidence | resolved scope, exclusions, resolution status |
| Finding verification (base) | occurrence evidence, repository intent | verification disposition with evidence references |
| Repair eligibility | occurrence evidence, recipe validation guidance, recipe standing | `repair_readiness` standing, scope correspondence, evidence references, rationale |
| Repair-scope correspondence | approved finding, proposed repair scope | within-finding / beyond-finding / unknown |

Code never infers meaning from text, keywords, or analyzer scores
(`MAINT-OPT-050`). An unavailable, malformed, or `unknown` assessment is not
a pass: it never satisfies a selection standing
(`MAINT-OPT-052`), and no assessment outcome waives a deterministic gate
(`MAINT-OPT-055`).

### Reconciling the confidence policy with Zero Framework Cognition

[#4495](https://github.com/viamin/paid/issues/4495) records the owner's
decision as a **confidence threshold**: only findings above a configured
threshold are queued. That decision is preserved as the shape of the policy —
a configured threshold, evaluated per run, on findings only. What it does not
license is a calibrated number.

Zero Framework Cognition puts semantic judgment in the AI call and policy in
the code. A probability emitted by a model is not calibrated, and inventing a
numeric scale here would create a false precision that no measurement in this
repository supports. The reconciliation is therefore:

- The threshold applies to the **repair-eligibility assessment's own discrete,
  ordered standing**, not to a probability and not to an analyzer score
  (`MAINT-OPT-051`, `MAINT-OPT-052`).
- The standing vocabulary is `supported`, `marginal`, `unsupported`, and
  `unknown`. It is a *selection standing*, not a score: no percentage, no
  calibration claim, no cross-recipe comparability claim.
- `unknown` never qualifies, under any configuration
  (`MAINT-OPT-052`).
- The configured minimum standing defaults to `supported` — the standing that
  demands the strongest evidence — because the family is opt-in and the
  failure mode of a wrong automatic repair is worse than the failure mode of a
  skipped one. This is a default, not a new product decision; the owner's
  election may set any standing the assessment can produce.
- The evidence behind a standing is recorded with the assessment, so a
  reviewer can judge the standing rather than trust a bare number.

## Bounded automatic repair

### Election

Automatic repair is a **per-run election captured at run start**, offered on
the UI, API, and MCP surfaces with equivalent authorization
(`MAINT-OPT-040`). It is never a tenant-wide or recipe default, it is off
when omitted, and the family adds no flag or tenant switch of its own
(`MAINT-OPT-004`). The snapshot records the election: enabled or not, the
minimum standing required, the per-repair cost and time caps, and the
categories the election covers (`MAINT-OPT-041`). A run without the election
behaves exactly like a report-only run.

The election can only narrow what qualifies. It selects among the categories
whose catalog standing already permits automatic repair; naming a
`manual_only` or `default_deny` category in the election changes nothing,
because the standing is catalog state and only a separate owner authorization
moves it (`MAINT-OPT-047`, `MAINT-OPT-048`).

### What the election does and does not change

The election changes **which qualifying findings start a repair run**. It
changes nothing about the report: the full report is delivered whether or not
any finding qualifies (`MAINT-OPT-042`), findings that do not qualify remain
manually selectable through the base repair pathways with their exclusion
reason recorded (`MAINT-OPT-043`), and every automatic-repair decision —
queued, skipped, failed — is recorded on the report
(`MAINT-OPT-049`). A skipped or failed auto-queue is never dropped silently.
Each queued repair carries the base provenance link back to its source report
and canonical finding identity (`MAINT-OPT-042`, `MAINT-072`).

Only a report whose outcome is `completed` — every planned check finished —
can trigger the queue. A `partial`, `cancelled`, or `budget_exhausted` report
queues nothing and records that reason: an incomplete-coverage report is the
wrong basis for an automatic repair judgment (`MAINT-OPT-042`).

### Deterministic gates

Before any repair is queued, code applies, in order:

1. The base `maintenance_runs` tenant guard (`MAINT-OPT-001`).
2. The presence and validity of the run-start election (`MAINT-OPT-041`).
3. The finding's automatic-repair standing — `eligible` only; `manual_only`
   and `default_deny` never qualify (`MAINT-OPT-047`, `MAINT-OPT-048`).
4. The initiator's authorization for the repair-creation pathway — an
   auto-queue never exceeds the authority of the user who elected it
   (`MAINT-OPT-053`).
5. The assessed standing against the configured minimum, with `unknown`
   excluded (`MAINT-OPT-052`).
6. The election's per-repair cost and time caps; exhaustion preserves the
   evidence collected so far (`MAINT-OPT-044`).
7. The canonical-finding idempotency check (`MAINT-OPT-046`).
8. The revision-revalidation check against the repair checkout
   (`MAINT-OPT-045`).

Authorization is checked before the eligibility assessment so that a run that
may not repair anything never pays for the semantic call.

The repair that starts is bounded to the approved finding; a repair that
needs changes beyond that finding requires explicit human authorization
(`MAINT-OPT-054`). Every gate is enforced in code, and no semantic result
can override one (`MAINT-OPT-055`).

### Manual-only and default-deny categories

Security-hardening findings are excluded from automatic repair entirely: they
stay report-only with manual selection until a dedicated accuracy and safety
review, separately authorized, admits them (`MAINT-OPT-047`). The remaining
staged recipe types are default-deny for automatic repair until a separate
owner authorization changes their standing (`MAINT-OPT-048`). Neither exclusion
is a temporary implementation detail: both are catalog state, visible on the
type and on the report, and no run-start election can lift either one.

## Issue mapping

The optimization family is tracked by an umbrella and four executable
children. **#4492 is a tracking umbrella**: its own acceptance is a final
evidence audit after its children, not an implementation prerequisite, and no
child waits for it. The executable deliverables are #4493–#4496.

| Contract area | Specs | Deliverable |
| --- | --- | --- |
| Catalog, curated type menu, snapshot persistence, degradation | `MAINT-OPT-010`–`MAINT-OPT-017` | [#4493](https://github.com/viamin/paid/issues/4493) (OPT-01) |
| Recipe definitions, provenance, prompt-only honesty, duplication and performance cautions | `MAINT-OPT-020`–`MAINT-OPT-027` | [#4494](https://github.com/viamin/paid/issues/4494) (OPT-02) |
| Optimization scope forms, resolution, broad scope, recommendation bound | `MAINT-OPT-030`–`MAINT-OPT-035` | [#4493](https://github.com/viamin/paid/issues/4493) (catalog and run snapshot), executed with #4494's recipes |
| Election, standing threshold, budgets, revalidation, idempotency, security exclusion, staged default-deny | `MAINT-OPT-040`–`MAINT-OPT-049` | [#4495](https://github.com/viamin/paid/issues/4495) (OPT-03) |
| Semantic assessment contract and the deterministic gate set | `MAINT-OPT-050`–`MAINT-OPT-056` | [#4495](https://github.com/viamin/paid/issues/4495) (OPT-03) |
| Staged recipe types and their standing | `MAINT-OPT-011`, `MAINT-OPT-048`, recipe content `MAINT-OPT-020` | [#4496](https://github.com/viamin/paid/issues/4496) (OPT-04) |
| Family admission, guard, and no-second-flag boundary | `MAINT-OPT-001`–`MAINT-OPT-006` | [#4493](https://github.com/viamin/paid/issues/4493), enforced with the base guard |
| Tracking umbrella, final audit only | — | [#4492](https://github.com/viamin/paid/issues/4492) |

Prerequisites that are not part of this family: base maintenance acceptance
([#4635](https://github.com/viamin/paid/issues/4635)) and the live
execution-environment evidence for native analyzers
([#4604](https://github.com/viamin/paid/issues/4604)) remain independent
dependencies of the implementation issues. Acceptance of this segment's
policy revisions is tracked by
[#4636](https://github.com/viamin/paid/issues/4636) and is a human action.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Type extensibility | Code-defined catalog entries surfaced as a menu | A hard enum on the run contract; a project-admin authoring UI | A new type must be a catalog entry only; an enum turns a menu into a migration every time the product learns a new category, and an authoring UI is product surface nobody has asked for (#4493). |
| Type selection with no packaged recipe | Degrade to a custom-objective investigation and disclose it | Reject the request; pretend the packaged recipe ran | The menu lists seven types from the start while recipes land in stages; failing closed would make the catalog unusable, and claiming recipe-backed coverage would be the dishonest outcome the family exists to avoid (MAINT-OPT-016). |
| Scope form | Paths, symbols, or free-text natural language | Paths and symbols only | Owners name areas ("the checkout page", "the sync feature") rather than paths; scope still bounds recommendations, not evidence (MAINT-OPT-030, `MAINT-OPT-034`). |
| Automatic-repair authorization point | A per-run election captured at run start | Tenant-wide setting; recipe default; election at report time | #4495's owner decision is opt-in and per-run; a tenant-wide or recipe-wide default would authorize repairs nobody elected, and an election taken after the report would let the report itself pressure the choice. |
| Selection threshold semantics | The assessment's own discrete, ordered standing | A numeric probability; the raw analyzer confidence score; no threshold at all | The owner decision is a configured threshold on findings, but a model-emitted probability is not calibrated and an analyzer score is not a repair judgment. A discrete standing keeps judgment in `agent_harness` and policy in code without inventing numerical semantics (`MAINT-OPT-051`, `MAINT-OPT-056`). |
| Default minimum standing | `supported`, the standing that demands the strongest evidence | A permissive default | The family is opt-in and automatic; a wrong automatic repair costs more than a skipped one, and the election can loosen it deliberately. |
| `unknown` assessments | Never auto-queued, under any configuration | Treat unknown as marginal | Unknown is the absence of a judgment; admitting it would let an unavailable or malformed assessment authorize a repair (`MAINT-OPT-052`). |
| Security hardening | Manual selection only until a separate policy review | Auto-queue eligible like the other categories | #4495 and #4496 exclude it explicitly; a dedicated accuracy and safety review, separately authorized, is the only path to changing that (`MAINT-OPT-047`). |
| Staged recipe types | Default-deny for automatic repair | Eligible by default | Their evidence quality is unproven, and default-deny keeps the elected path narrow while the recipes accumulate evaluation evidence (`MAINT-OPT-048`). |
| Repair scope | Bounded to the approved finding | Whatever the agent judges necessary | The owner's decision keeps repair scope bounded to the approved finding; anything broader requires explicit human authorization (`MAINT-OPT-054`). |
| Report outcome that may trigger the queue | `completed` only | `partial` as well | An incomplete-coverage report is a weak basis for an automatic repair judgment; queueing from it would trade honest coverage for automation. Revisit with evaluation evidence, not by default (`MAINT-OPT-042`). |
| Report integrity under an election | The full report is always delivered | The report is filtered to queued findings | The election selects repair work, not content; a filtered report would hide evidence the owner needs to judge the election's effect (`MAINT-OPT-042`). |
| Idempotency key | Canonical finding identity | Per-occurrence identity; per-run identity | Repeated scans reproduce the same canonical finding; keying on the occurrence would queue duplicate repairs for one finding, and keying on the run alone would re-queue a finding the user already repaired (`MAINT-OPT-046`). |

## Open Questions & Future Decisions

### Resolved

1. ✅ The family's automatic-repair path is an election on a maintenance run,
   not a new run goal and not a new report model
   (`MAINT-OPT-003`, `MAINT-OPT-006`).
2. ✅ The confidence threshold is expressed over the assessment's discrete
   standing, with no calibrated numeric semantics
   (`MAINT-OPT-051`, `MAINT-OPT-052`).

### Deferred

1. The rubric that maps collected evidence onto a standing — and the recipe
   prompt that applies it — are written during implementation of #4495. This
   LLD fixes the standing vocabulary (`supported`, `marginal`, `unsupported`,
   `unknown`), its ordering, and the fail-closed rule; it does not fix the
   prompt wording.
2. The default cost and time caps per auto-queued repair run, and whether the
   election also carries an aggregate cap for one report, are resolved during
   #4495's implementation against measured repair cost.
3. Whether a staged type's standing changes from `default_deny` to
   `eligible` requires its own owner authorization and evaluation evidence;
   this segment does not schedule that decision.
4. The concrete recipe content for the staged types (evidence collectors,
   metric hints, validation guidance) belongs to #4496, and the
   reconciliation with RDR-075's future test-quality recipe belongs there
   too.
5. Whether advisory PR integration reuses optimization evidence is owned by
   the base maintenance segment and remains a later, separately approved
   policy decision.

## What This Is Not

- Not a new run goal, report model, or finding model — the family is a
  recipe family inside the maintenance lifecycle (`MAINT-OPT-003`).
- Not a new tool catalog or provisioning path — RDR-073's attachment
  lifecycle is consumed (`MAINT-OPT-021`).
- Not a rollout enablement — every claim rides the base `maintenance_runs`
  guard, and this segment changes no flag (`MAINT-OPT-001`,
  `MAINT-OPT-004`).
- Not an in-scan repair path — a scan never mutates source code; an elected
  automatic repair is a separate run that starts after the report and passes
  every gate (`MAINT-OPT-053`, `MAINT-OPT-055`).
- Not a security-repair authorization — security findings stay manual-only
  until a separate policy review (`MAINT-OPT-047`).

## References

- [RDR-075 draft](../../rdrs/RDR-075-general-maintenance-runs.md) — base
  general maintenance runs design
- [base maintenance LLD](../maintenance-runs/maintenance-runs-design.md) and
  [EARS](../maintenance-runs/maintenance-runs-specs.md) — the contracts this
  family consumes
- [#4492](https://github.com/viamin/paid/issues/4492) — optimization family
  umbrella (tracking only) ·
  [#4493](https://github.com/viamin/paid/issues/4493) catalog ·
  [#4494](https://github.com/viamin/paid/issues/4494) first recipes ·
  [#4495](https://github.com/viamin/paid/issues/4495) auto-queue policy ·
  [#4496](https://github.com/viamin/paid/issues/4496) staged recipes
- [#4635](https://github.com/viamin/paid/issues/4635) — base maintenance
  acceptance ·
  [#4636](https://github.com/viamin/paid/issues/4636) — this segment's
  acceptance ·
  [#4604](https://github.com/viamin/paid/issues/4604) — live tool-handoff
  evidence
- [layered-verification LLD](../layered-verification/layered-verification-design.md)
  — the sibling audit/repair separation pattern this family follows
- `app/models/agent_run.rb` — `execute_in_execution_environment`
