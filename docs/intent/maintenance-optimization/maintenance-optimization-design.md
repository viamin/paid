---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Maintenance Optimization Recipes

> **Draft — pending design acceptance.** Extension of the draft
> [`maintenance-runs`](../maintenance-runs/maintenance-runs-design.md)
> segment (itself pending acceptance of draft
> [`RDR-075`](../../rdrs/RDR-075-general-maintenance-runs.md) via
> [#4635](https://github.com/viamin/paid/issues/4635)). This LLD reconciles
> the product-owner decisions recorded in
> [#4495](https://github.com/viamin/paid/issues/4495) (agreed 2026-10-16) and
> the family scope recorded in
> [#4492](https://github.com/viamin/paid/issues/4492) into a reviewable
> contract. It is **not accepted intent**: it authorizes no implementation,
> no runtime behavior, and no rollout. The executable deliverables it maps to
> ([#4493](https://github.com/viamin/paid/issues/4493)–[#4496](https://github.com/viamin/paid/issues/4496))
> stay blocked on acceptance of this segment and of the base maintenance
> design. Preparation tracked by
> [#4636](https://github.com/viamin/paid/issues/4636).

## Purpose

The optimization family is a recipe family inside general maintenance runs:
non-functional "contracting" audits that make a project more efficient
without adding functionality — code duplication, maintainability,
performance first, with security hardening, cost efficiency,
design/architecture, and test quality staged behind them. A user starts an
optimization audit like any maintenance run (report-only per RDR-075),
selecting a type from a curated menu with a free-form natural-language
scope, receives the cited report, and chooses bounded repairs from
findings. Optionally — and only by an explicit per-run election at start —
bounded repair runs are queued automatically once the report completes.

Base RDR-075 excludes automatic repair without a separately approved policy
("Automatic repair is outside the initial scope and requires a separately
approved policy"). This segment is that policy's draft, narrowly scoped to
the optimization family: opt-in, off by default, budgeted, revalidated, and
excluded for security-category findings until a separate review admits
them.

## Relationship to Base Maintenance Contracts

This segment is an overlay, not a parallel system. Optimization runs **are**
maintenance runs: they reuse the maintenance goal, admission and rollout
guard (`maintenance_runs`, default off), objective/scope/guidance snapshots,
report/finding-occurrence identity, coverage honesty, and the bounded
repair handoff owned by
[`maintenance-runs`](../maintenance-runs/maintenance-runs-design.md)
(`MAINT-001`–`MAINT-073`). Nothing here re-states those contracts as family
policy; family specs below cite the base claim they ride. Where the family
genuinely extends a base contract, the base claim was reconciled in place:

- `MAINT-011` accepts free-form natural-language scope text as a scope form
  (files, a feature, a page in the app), not only paths/symbols — the
  family's broad-recommendation scope is valid base scope.
- `MAINT-073` recognizes a run-start election made under a separately
  approved selection policy as an explicit recorded user selection; the
  base default remains report-only with no election.

Two contracts remain unchanged and load-bearing: RDR-073's tool guard stays
separately authoritative for analyzer admission, and [#4604](https://github.com/viamin/paid/issues/4604)'s
live tool-handoff evidence stays a prerequisite for any tool-assisted recipe
implementation (base deferred decision 5).

## Recipe Catalog

The family's extensibility lives in a **code-defined type catalog**, not in
the run contract. Each entry carries a display name, a description of what
the agent looks for, default metric hints (e.g. latency reduction,
complexity decrease, duplicated lines removed), and a pointer to the
underlying recipe definition when one exists. The initial catalog holds
seven types: Performance; Design / Architecture; Code Duplication; Security
Hardening; Cost / Resource Efficiency; Maintainability / Readability; and
Test Coverage & Quality.

Adding a type is a catalog entry plus (when the type is ready) its recipe
definition — no enum, migration, or run-contract change. Unmapped type
values degrade to a custom-objective maintenance run rather than erroring.
There is no project-admin authoring surface in v1; the catalog is
code-defined and versioned with the application.

The curated menu is presentation over the catalog: it appears wherever
maintenance runs are started — the trigger-agent-run form, chat, and the
API/MCP surfaces — with equivalent authorization, and a run remains
startable without selecting a type. A selected type is recorded on the run
snapshot alongside objective/scope/guidance at start, immutable after
start, and retained across retries (the `MAINT-015` snapshot contract).

## Recipe Execution

A recipe definition supplies the objective, investigation instructions,
applicable evidence collectors, validation guidance, and default metric
hints (the catalog contract above). Recipes ride the base tool-integration
contract: analyzers attach through RDR-073 marketplace matching or the
native-CLI execution-environment path, resolution is per
package/ecosystem for polyglot repositories, and provenance
(name/version/configuration) is recorded on every finding and report that
used a tool (`MAINT-040`–`MAINT-043`).

The first three recipes are chosen for a mix of ready tool evidence and
prompt-first value:

1. **Code Duplication** — tool-assisted (PMD CPD for cross-language
   duplication; Exhale/Debride-class analyzers for Ruby where applicable).
   RDR-075's false-positive cautions are binding: similarity alone does not
   establish that code should be shared; deliberate independence, framework
   callbacks, reflection, and compatibility obligations are considered
   through semantic assessment before a consolidation finding is proposed.
2. **Maintainability / Readability** — tool-assisted where available
   (complexity analysis), agent-assessed: cognitive-complexity regressions,
   overly complex functions, naming/documentation gaps, each with a
   proposed action.
3. **Performance** — prompt-first initially, with no blocking analyzer
   dependency: investigation of hot paths, algorithmic improvements, and
   N+1/IO patterns within scope, with metric hints recorded on findings.
   Tool-assisted profiling can extend this recipe later without contract
   changes.

Where a recipe has no credible tool evidence path, it lands prompt-first
and records that honestly in reports (`MAINT-044` fallback); a prompt-only
investigation that completes with no findings reports `clean`, never a
fabricated tool provenance.

The staged follow-on types — Security Hardening, Cost / Resource
Efficiency, Design / Architecture, Test Coverage & Quality — register
through the same catalog only after the first three recipes' evaluation
evidence (on at least one non-Paid project per recipe) supports them. Test
Coverage & Quality reconciles with RDR-075's stated future "test quality"
recipe rather than duplicating it: one recipe, reached from both intents.

## Scope and Honest Evidence

Optimization scope is free-form natural language by default: files, a
feature, or a page in the app are all valid, with no scope limits imposed
by the family. Named targets resolve before coverage is claimed; ambiguity
produces an actionable clarification outcome, and an unnamed scope is
recorded as explicit broad scope (`MAINT-012`–`MAINT-014`).

Scope bounds **recommendations**, not evidence access: the agent may
inspect callers, tests, framework entry points, and design documents
elsewhere in the repository to validate a claim, and must explain any
recommendation requiring changes beyond the requested scope; expanding
repair scope requires explicit authorization (unchanged RDR-075 and
`MAINT-071` scope-preservation contract).

Honesty rules are the base report contract, restated here because the
family's value depends on them: a report distinguishes actionable
findings, unresolved candidates, deliberate exceptions, and coverage
limitations; missing tools, parse failures, truncation, and budget
exhaustion are visible incomplete coverage, never a clean result
(`MAINT-020`–`MAINT-025`); repeated scans update finding occurrences
rather than duplicating repair work (`MAINT-027`).

## Semantic Assessment

Zero Framework Cognition governs the split of labor. Code owns I/O,
structural validation, policy enforcement (authorization, budgets,
idempotency, admission), and state. Semantic judgment — whether a
candidate finding is real, whether evidence supports a repair, whether
independence is deliberate — belongs to LLM calls made through
`agent_harness` with a structured response schema, never to keyword or
regex matching in control-plane code. Tool evidence identifies candidates;
the agent assesses meaning; every finding occurrence carries a
verification disposition distinct from any raw tool-confidence score
(`MAINT-025`).

### Repair-eligibility standing

The owner decision in #4495 records the auto-queue selection policy as a
"confidence threshold". A model-emitted probability is not calibrated, and
inventing a numeric scale no measurement in this repository supports would
be false precision. The policy's *shape* is preserved — a configured
threshold, evaluated per run, on findings only — and applied to the
repair-eligibility assessment's own **discrete, ordered standing**:

- `supported` — the finding's evidence and verification disposition
  support the proposed action, and revalidation is expected to succeed;
- `marginal` — the finding is plausible but the evidence or disposition
  leaves material doubt;
- `unsupported` — counterevidence or failed verification predominates;
- `unknown` — assessment could not run or returned no valid result.

`unknown` is distinct from `unsupported` and never qualifies for automatic
repair under any configuration. A raw analyzer confidence score is never
the threshold input. The standing rubric and model provenance are recorded
with each assessment (versioned, as the facet-confidence segment versions
its rubric), so later rubric changes cannot silently requalify old
reports.

## Bounded Automatic Repair

Automatic repair exists only as the **opt-in, pre-authorized selection
policy** agreed with the product owner (2026-10-16), drafted here as
RDR-075's separately approved policy for this family:

- **Opt-in only, off by default.** The election is a per-run choice made at
  start on the trigger form and API/MCP surfaces — never a tenant-wide or
  recipe default. An omitted election behaves exactly like report-only.
- **Threshold on standing.** Only findings whose repair-eligibility
  standing meets the configured minimum are queued. The default minimum is
  `supported` — the strictest standing — because the family is opt-in and
  automatic, and a wrong automatic repair costs more than a skipped one.
- **Budget caps per repair run.** Every auto-queued repair run carries
  explicit cost/time limits recorded at election; exhaustion preserves
  collected evidence per the base contracts. No unbudgeted dispatch.
- **Revalidation required.** Auto-queued repairs go through the base repair
  handoff (`MAINT-070`–`MAINT-073`) unchanged, including revalidation
  against the repair checkout when the target revision has moved. Stale
  evidence can never silently authorize a repair.
- **Scope preservation.** Repair scope stays bounded to the approved
  finding; anything broader requires explicit human authorization.
- **Idempotency on finding identity.** Repeated occurrences of the same
  canonical finding identity do not queue duplicate repair work; the
  idempotency key is the canonical finding (`MAINT-026`), not the
  occurrence or the run.
- **Completed reports only.** Automatic dispatch is evaluated only when the
  report outcome is `completed`. A `partial`, `cancelled`, or
  `budget_exhausted` report queues nothing and records why, so incomplete
  coverage never launder into authorized repairs.
- **The election can only narrow.** Each catalog type carries an
  automatic-repair standing — `eligible`, `manual_only`, or
  `default_deny`. The run-start election may lower what is queued (raise
  the minimum standing, exclude categories); it may never widen a
  `manual_only` or `default_deny` catalog standing. Only a separate owner
  authorization moves a catalog standing.
- **Security stays manual-only.** Security Hardening carries `manual_only`
  standing: its findings are report-only with manual repair selection
  until a dedicated accuracy and safety review — separately authorized —
  finds auto-queued hardening repairs meet confidence and blast-radius
  standards.
- **Staged types default-deny.** Cost / Resource Efficiency,
  Design / Architecture, and Test Coverage & Quality carry `default_deny`
  automatic-repair standing until separate owner authorization with
  evaluation evidence admits them.

The report is always delivered in full; findings below the threshold
remain available for manual selection through the unchanged base handoff.
Disabling the `maintenance_runs` guard stops new auto-queues without
cancelling active repair runs or deleting reports (`MAINT-004` rollback
parity). The election snapshot is immutable after run start and retained
across retries.

## Issue Mapping

| Deliverable | Claims | Content |
| --- | --- | --- |
| [#4493](https://github.com/viamin/paid/issues/4493) (OPT-01) | `MAINT-OPT-001`–`MAINT-OPT-009` | Catalog, curated type menu on all surfaces, snapshot retention, unmapped fallback |
| [#4494](https://github.com/viamin/paid/issues/4494) (OPT-02) | `MAINT-OPT-010`–`MAINT-OPT-018`, `MAINT-OPT-020`–`MAINT-OPT-025` | First three recipes, false-positive cautions, prompt-first honesty, scope semantics |
| [#4495](https://github.com/viamin/paid/issues/4495) (OPT-03) | `MAINT-OPT-030`–`MAINT-OPT-034`, `MAINT-OPT-040`–`MAINT-OPT-056` | Standing assessment, opt-in election, threshold, budgets, revalidation, idempotency, security exclusion |
| [#4496](https://github.com/viamin/paid/issues/4496) (OPT-04) | `MAINT-OPT-001`, `MAINT-OPT-002`, `MAINT-OPT-047`, `MAINT-OPT-048` | Staged follow-on recipes through the catalog, security manual-only enforcement, `default_deny` standings, test-quality reconciliation |

[#4492](https://github.com/viamin/paid/issues/4492) is the tracking
umbrella: it tracks final evidence-based acceptance across these four
executable deliverables and is not itself an implementation prerequisite.
Base acceptance ([#4635](https://github.com/viamin/paid/issues/4635)) and
the live tool-handoff evidence
([#4604](https://github.com/viamin/paid/issues/4604)) remain independent
prerequisites of every runtime child.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Selection-policy semantics | Configured threshold on discrete ordered standing (`supported`/`marginal`/`unsupported`/`unknown`); raw analyzer confidence never the input | Numeric confidence threshold on a model- or tool-emitted score | #4495 records a confidence threshold; ZFC puts semantic judgment in the AI call and policy in code, and a model-emitted probability is not calibrated — inventing a numeric scale would be false precision no measurement here supports. The discrete standing preserves the decision's shape (per-run configured threshold, findings only). |
| Default minimum standing | `supported` (strictest qualifying standing) | `marginal` to queue more repairs | Opt-in and automatic: a wrong automatic repair costs more than a skipped one; the owner can lower it per run. |
| Automatic-repair trigger | `completed` reports only | Also allow `partial` reports | Incomplete coverage must never become authorized repairs; a `partial` report's findings can still be selected manually. |
| Election authority | Election may only narrow catalog standings; never widen `manual_only`/`default_deny` | Let an authorized election override catalog standings at run start | Catalog standings encode owner-level risk decisions (security, staged types); a per-run user choice must not rewrite owner policy. |
| Idempotency key | Canonical finding identity (`MAINT-026`) | Occurrence or run identity | Keying on the occurrence or run would queue duplicate repair work for a repeated finding — exactly what the base recurring-identity contract exists to prevent. |
| Automatic repair for security | Excluded (`manual_only`) until a separately authorized review | Include with a higher standing threshold | #4496's staging decision: no evidence yet that auto-queued hardening repairs meet confidence and blast-radius standards. |
| Catalog representation | Code-defined catalog; menu is presentation | Enum column on the run contract; project-admin authoring UI | New types must not require enum migrations or run-contract changes; authoring UI is unneeded before the family proves value. |
| Where the family's base exceptions live | Base claims reconciled in place (`MAINT-011` scope form, `MAINT-073` election-as-selection) | Carry both exceptions only in this segment | The base contract read cold would otherwise contradict shipped family scope; in-place reconciliation keeps one canonical wording per claim. |

## Open Questions & Future Decisions

### Pending owner acceptance ( [#4636](https://github.com/viamin/paid/issues/4636) )

1. Confidence-threshold → discrete-standing semantics
   (`MAINT-OPT-032`, `MAINT-OPT-051`, `MAINT-OPT-052`).
2. Default minimum standing `supported` (`MAINT-OPT-041`).
3. Automatic dispatch on `completed` reports only (`MAINT-OPT-042`).
4. Election-can-only-narrow (`MAINT-OPT-041`, `MAINT-OPT-047`,
   `MAINT-OPT-048`).
5. Security hardening `manual_only` (`MAINT-OPT-047`).
6. Staged types `default_deny` (`MAINT-OPT-048`).
7. Idempotency keyed on canonical finding identity (`MAINT-OPT-046`).
8. Base-claim reconciliation (`MAINT-011`, `MAINT-073`).

### Deferred

1. Concrete election payload shape (threshold surface, budget defaults) and
   catalog storage table/columns — resolve at #4493/#4495 implementation,
   after acceptance.
2. Standing rubric content and prompt-schema details — owned with the
   first recipe evaluation (#4494), versioned from the first shipped
   assessment.
3. Whether the election is exposed on recurring maintenance schedules — a
   schedule is not a run start; deciding this belongs to the base
   scheduling contract's own follow-up, not this family.
4. Conditions under which the security review (#4496 stage 1) may admit
   security auto-repair — set when that review is separately authorized.

## What This Is Not

- Not an authorization to implement: every claim is `[ ]` and blocked on
  acceptance of this segment and the base design (#4635).
- Not a second feature flag: the family rides the base `maintenance_runs`
  guard (default off); RDR-073's tool guard remains separately
  authoritative.
- Not a widening of base authority: report-only remains the default;
  automatic repair exists only as the per-run, budgeted, revalidated,
  security-excluded election defined above.
- Not a new confidence system: the standing is a repair-eligibility
  rubric, not a calibrated probability and not a second facet-confidence
  scoreboard.

## References

- [RDR-075 draft](../../rdrs/RDR-075-general-maintenance-runs.md) —
  family named as the separately approved automatic-repair policy's draft
- [maintenance-runs LLD](../maintenance-runs/maintenance-runs-design.md)
  and [EARS](../maintenance-runs/maintenance-runs-specs.md) — base
  contracts this overlay rides
- [#4492](https://github.com/viamin/paid/issues/4492) (umbrella),
  [#4493](https://github.com/viamin/paid/issues/4493)–[#4496](https://github.com/viamin/paid/issues/4496)
  (deliverables), [#4635](https://github.com/viamin/paid/issues/4635)
  (base acceptance), [#4604](https://github.com/viamin/paid/issues/4604)
  (live tool-handoff evidence), [#4636](https://github.com/viamin/paid/issues/4636)
  (this preparation)
- [facet-confidence](../facet-confidence/facet-confidence-design.md) —
  precedent for versioned rubrics and unknown-distinct-from-failure
  semantics
- [agent-harness-integration](../agent-harness-integration/agent-harness-integration-design.md)
  — the single application LLM interface all semantic assessment uses
