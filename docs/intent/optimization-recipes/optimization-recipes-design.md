---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipes

> **Draft — pending design acceptance.** Companion to
> [`docs/high-level-design.md`](../../high-level-design.md), the
> [`maintenance-runs`](../maintenance-runs/maintenance-runs-design.md) LLD it
> extends, and the draft
> [`RDR-075`](../../rdrs/RDR-075-general-maintenance-runs.md) design
> (Status: Draft). This LLD and its EARS specs are a reviewable contract
> produced for the human review gate; they are not accepted intent and
> authorize no implementation, no rollout, and no automatic repair.

## Purpose

Paid's general maintenance capability investigates a repository and reports
what it found. The optimization recipe family is the recipe catalog for
*contracting* audits: non-functional investigations that make a project more
efficient without adding functionality — duplication, maintainability,
performance, security hardening, cost, architecture, and test quality.

This LLD owns the optimization catalog and its type selection, the scope
semantics of an optimization run, the honest-evidence contract for
optimization recipes, the semantic repair-eligibility assessment, and the
bounded automatic-repair policy that RDR-075 requires to be approved
separately before any scan may queue repair work.

It does not own maintenance runs, reports, finding identity, tool
attachment, or the repair-handoff pathway itself. Those belong to the
[`maintenance-runs`](../maintenance-runs/maintenance-runs-design.md) segment
(`MAINT-001`–`MAINT-073`) and are consumed here, not restated.

The family is delivered as four issues. [#4493](https://github.com/viamin/paid/issues/4493)
delivers the catalog and type menu; [#4494](https://github.com/viamin/paid/issues/4494)
delivers the first three recipes; [#4495](https://github.com/viamin/paid/issues/4495)
delivers the bounded automatic-repair policy; and
[#4496](https://github.com/viamin/paid/issues/4496) delivers the staged
follow-on types. [#4492](https://github.com/viamin/paid/issues/4492) is the
tracking umbrella and owns no executable claim.

## Catalog and Type Selection Contract

The optimization catalog is a code-defined registry of typed entries. It is
presentation over recipe definitions, not a hard enum in the run contract: a
new type is a new entry, and no type is a column, an enum, or a migration.

Each catalog entry carries:

- A stable identifier used in the run snapshot and in reports.
- A display name and a description of what the agent looks for.
- Default metric hints — for example latency reduction, complexity decrease,
  duplicated lines removed — recorded on the findings the recipe produces.
- A pointer to the underlying recipe definition, when one exists. A catalog
  entry without a recipe definition describes an intent the agent investigates
  prompt-first.
- A **repair standing** that governs whether findings of this type may ever be
  queued automatically (see *Bounded Automatic Repair Policy*).

The seven initial types are:

| Identifier | Display name | Recipe |
| --- | --- | --- |
| `performance` | Performance | Prompt-first; tool-assisted profiling may extend it without a contract change. |
| `design_architecture` | Design / Architecture | Prompt-first; findings framed as proposed actions, not auto-applicable rewrites. |
| `code_duplication` | Code Duplication | Tool-assisted. |
| `security_hardening` | Security Hardening | Tool-assisted where a static analyzer applies. |
| `cost_resource_efficiency` | Cost / Resource Efficiency | Prompt-first initially. |
| `maintainability_readability` | Maintainability / Readability | Tool-assisted where a complexity analyzer applies; agent-assessed. |
| `test_coverage_quality` | Test Coverage & Quality | Prompt-first initially. |

Selection is presentation. Where a maintenance run is started, the UI, the
authenticated API, and the MCP surface each surface the same type menu with
the same entries, and each applies the same project-scoped start
authorization. A run with no type selected, or with a type value that is not
in the catalog, starts as a custom-objective investigation: the unmapped value
is recorded on the run so the report can explain it, and the start never
fails on the selection alone.

The selected type is part of the run snapshot alongside the objective, scope,
guidance, and limits, and it survives retries of that run.

## Scope Contract

An optimization run's scope may be paths, symbols, or a free-form
natural-language target — a file, a feature, a page in the application. There
is no limit on the breadth of a natural-language scope: a user may name "the
checkout flow" and the investigation resolves that target. A named target is
resolved before any check claims coverage of it, and the report records the
resolved scope and any exclusions, distinct from what the user asked for.

Scope bounds **recommendations**, not **evidence access**. An investigation
may inspect callers, tests, framework entry points, and design documents
outside the requested scope to validate a claim. What scope does bound is the
change a finding may propose: a proposed action that extends beyond the
requested scope is marked as requiring explicit human authorization and is
never eligible for automatic repair.

## Recipe Execution and Honest Evidence

A recipe definition supplies an objective, investigation instructions, the
applicable evidence collectors, validation guidance, and default metric
hints. The recipe is what makes a type a distinct investigation rather than a
label on a generic prompt.

Evidence is reported as it was collected:

- Where a tool attaches, the analyzer name, version, and configuration are
  recorded as provenance on the findings and the report that used them.
- Where no tool applies to the recipe for the run's repository, the
  investigation completes prompt-first and the report says so. A recipe with
  no tool path is a supported path, not a degraded one; the report's
  completed-checks list is what distinguishes incomplete coverage, never the
  presence of findings.
- A duplication analyzer's output is candidate evidence, not a verdict.
  Similarity alone does not establish that code should be shared, and
  deliberate independence, framework callbacks, and dynamic invocation are
  part of what a finding must record having considered before it recommends
  consolidation or deletion.
- Every optimization finding carries the base maintenance finding contract:
  category, affected locations and symbols, claim, supporting evidence,
  known counterevidence, proposed action, validation plan, and a verification
  disposition that is distinct from any raw tool-confidence score.

A repeated scan of the same project observes the same canonical finding and
updates its occurrence instead of producing new repair work, exactly as the
base maintenance finding-identity contract requires.

Each recipe's evaluation evidence — actionable findings, false positives,
unresolved coverage, latency, token and tool cost, repeated-finding noise,
and repair review outcomes — is recorded against at least one project outside
Paid's own repository before that recipe's delivery is closed.

## Semantic Repair-Eligibility Assessment

A repair-eligibility assessment answers one question: does this finding's
evidence support applying its proposed action automatically, or does it
require a person to choose?

The judgment is semantic, so it belongs to an AI call. Paid's Zero Framework
Cognition split applies: the assessment is produced by `agent_harness`
against a versioned rubric and returned as a structured result; application
code validates the result's structure and enforces the policy gates that
follow. Code never infers the judgment from a finding's text, its title, its
category string, or a raw analyzer confidence score.

The assessment result records the canonical finding it assessed, the rubric
version, the standing, an explanation, and the citations the assessment
relied on.

The standing is a bounded, ordered value:

| Standing | Meaning |
| --- | --- |
| `strong` | The evidence directly supports the proposed action, with no material counterevidence. |
| `supported` | The evidence supports the proposed action. |
| `exploratory` | The evidence suggests the proposed action, but not strongly enough to justify an automatic change. |
| `insufficient` | The evidence does not support the proposed action. |
| `unknown` | The assessment could not reach a standing. |

Standings are compared by their order, never by a numeric score. `unknown` is
an explicit value rather than a missing one, and it never qualifies under any
configuration: an assessment that is absent, malformed, of an unknown rubric
version, or bound to a different finding occurrence is treated as not
qualifying, and there is no fallback standing.

An assessment is bound to the evidence it assessed. When the finding
occurrence's recorded evidence changes materially, the assessment no longer
applies: the system re-assesses rather than acting on a stale judgment.

This is the reconciliation of the recorded "confidence threshold" decision with
Zero Framework Cognition. A threshold's *shape* is preserved — a configured
minimum, evaluated per run, over findings only — while its *number* is not
invented. A model-emitted probability is not a calibrated measurement, and no
measurement in this repository supports presenting one as a repair
authorization. The standing is an ordered, bounded, human-readable verdict;
the threshold compares standings.

## Bounded Automatic Repair Policy

RDR-075 states that automatic repair is outside its initial scope and requires
a separately approved policy. This section is that policy. It stays inert
until it is accepted, and nothing here authorizes an implementation.

**Opt-in, per run, off by default.** Automatic repair is a per-run election
captured at run start, on the same surfaces that start the run. It is never a
tenant-wide, project-wide, or recipe-wide default. A run that does not elect
it behaves exactly like a report-only run.

**A schedule cannot elect it.** The recorded election is made at run start by
a person. A standing schedule that carried an election would be a recipe
default by another name, which the policy excludes; schedules therefore
queue no automatic repair until a separate design says otherwise.

**Selection.** A finding is selected for automatic repair when its assessed
standing is at least the configured minimum standing, and its type's repair
standing permits automatic repair at all. The default minimum standing is
`supported`: the family is opt-in and its repair is automatic, so an unwanted
automatic change costs more than a skipped one, and the default requires the
assessment to affirm the action rather than merely suggest it.

**The election can only narrow.** A run-start election may require a stricter
minimum standing than the configured default. It can never widen a type's
repair standing, and it can never make a `manual_only` or `default_deny` type
eligible. Repair standings change only by a separate owner authorization
recorded against the catalog.

**Type repair standings.**

| Standing | Automatic repair |
| --- | --- |
| `auto_eligible` | Findings may be queued automatically once the standing and budget gates pass. |
| `manual_only` | Findings are reported for manual selection only. |
| `default_deny` | Findings are reported only; automatic repair waits for a separate owner authorization. |

`security_hardening` is `manual_only`. Its findings are report-only and are
selected by a person until a dedicated accuracy and safety review finds that
automatically queued hardening repairs meet the family's confidence and
blast-radius standards. Each newly staged type starts at `default_deny` and
moves only by that same owner authorization.

**Dispatch.** The report is always delivered in full, whatever was selected.
Only findings of a report whose outcome is `completed` are dispatched: a
`partial`, `cancelled`, or `budget_exhausted` report queues nothing and
records why. A dispatch goes through the base maintenance repair-handoff
pathway unchanged and links the repair run back to the source report and the
canonical finding identity.

**Revalidation.** Where the repair target's revision has moved since the
source report was generated, the finding's evidence is revalidated against
the repair checkout before the repair applies. Stale evidence never silently
authorizes a repair, and a failed revalidation surfaces visibly rather than
dropping the repair.

**Idempotency.** A canonical finding identity that already has a queued or
completed automatic repair is not dispatched again.

**Budgets.** Each automatically dispatched repair run carries explicit cost and
time caps. Where they are exhausted, the evidence collected so far is
preserved and the exhaustion is reported.

**Scope.** The repair stays bounded to the approved finding. A proposed
action extending beyond it requires explicit human authorization.

**Guard.** The whole family sits behind the base `maintenance_runs` rollout
guard. With the guard off for a tenant, no maintenance run is admitted and no
new automatic repair is queued; in-flight repair runs are not cancelled and
no report is deleted.

## Staged Optimization Types

The follow-on types land after the first three recipes have produced
evaluation evidence.

1. **Security Hardening** — static analyzers where available; findings about
   insecure patterns, secret exposure, and input validation. Repairs are
   `manual_only`.
2. **Cost / Resource Efficiency** — right-sizing, idle waste, unnecessary
   retries and data transfer. Prompt-first initially.
3. **Design / Architecture** — coupling, layering, and boundary
   recommendations. Prompt-first; findings are proposed actions rather than
   auto-applicable rewrites.
4. **Test Coverage & Quality** — untested branches, flaky candidates, and
   testability refactors. This type reconciles with RDR-075's planned
   test-quality recipe rather than defining a second, divergent one.

Each registers through the catalog with its metadata, evidence collectors, and
metric hints. None requires an enum change or a migration.

## API, UI, and MCP Parity

The type menu, the automatic-repair election, and the standing/caps defaults
are surfaced equivalently on the UI, the authenticated API, and the MCP
surface, each with the same project-scoped authorization. No surface offers a
thicker or thinner contract than another.

## Issue Mapping

| Issue | Owns |
| --- | --- |
| [#4493](https://github.com/viamin/paid/issues/4493) | Catalog entries, the type menu, snapshot persistence, unmapped fallback, guard behavior. |
| [#4494](https://github.com/viamin/paid/issues/4494) | The first three recipes, provenance, analyzer false-positive cautions, prompt-only honesty, recurring finding identity, evaluation evidence. |
| [#4495](https://github.com/viamin/paid/issues/4495) | The semantic assessment, the election, standing thresholds, dispatch, revalidation, idempotency, budgets, type repair standings, guard behavior. |
| [#4496](https://github.com/viamin/paid/issues/4496) | The four staged types, security `manual_only` enforcement, test-quality reconciliation, per-stage evaluation evidence. |
| [#4492](https://github.com/viamin/paid/issues/4492) | Tracking umbrella only. It owns no executable claim. |

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| How a type is expressed | A code-defined catalog entry | An enum column on runs; a free-text label | An enum makes every new type a migration and every unmapped value an error. A free-text label gives no metadata to present, no metric hints, and no place to record a repair standing. |
| What selects a finding for automatic repair | A bounded ordered standing from an `agent_harness` assessment | A numeric confidence threshold over model output; a raw analyzer confidence score | A model-emitted probability is not a calibrated measurement, and no measurement in this repository supports presenting one as an authorization. A raw analyzer score measures the analyzer's similarity or rule match, not whether the finding should be acted on. An ordered standing is auditable, bounded, and comparable by order rather than by an invented number. |
| Where the standing's order is defined | The rubric version recorded with the assessment | A per-run threshold constant; a global ordering table | The rubric is what produced the standing, so its version is what makes the standing interpretable. A rubric change invalidates prior assessments rather than silently reinterpreting them. |
| Who may change a type's repair standing | A separate owner authorization recorded against the catalog | The run-start election; the recipe definition | A standing is a safety property of a type, not a per-run preference. Letting a run widen it would make `manual_only` advisory, which is the opposite of what it means. |
| Default minimum standing | `supported` | `strong`; `exploratory` | `exploratory` would let findings the assessment only *suggests* change code. `strong` would require the assessment to find no material counterevidence at all, which the first recipes have no evaluation evidence to promise. `supported` requires the assessment to affirm the action. |
| When a dispatch may happen | Only after a `completed` report | After any terminal report | A partial report means some planned check did not complete, so the evidence base for a selection is known to be incomplete. Dispatching from it would contradict the report's own coverage statement. |
| Which scope form a run accepts | Paths, symbols, or a free-form natural-language target | Paths and symbols only | Users name a feature or a page, not always a path. Requiring a path would force the user to resolve the target themselves before asking the question the investigation is meant to answer. |
| Whether a schedule may elect automatic repair | No | Yes, as a schedule-level setting | The recorded decision is a per-run election made at run start. A standing election would be a recipe default by another name. |
| Where the type menu lives | In the run-start surface on all three surfaces | A separate catalog administration screen | The menu is a selection input, not a management surface. The catalog is code-defined, so there is nothing for an operator to administer at runtime. |

## Open Questions & Future Decisions

### Resolved

1. ✅ Whether the family is allowed to queue repair work at all — only
   through the separately approved policy in this LLD, and only for findings
   of a `completed` report.
2. ✅ Whether security findings may be repaired automatically — no;
   `manual_only` until a dedicated accuracy and safety review admits them.
3. ✅ Whether a staged type inherits the family's automatic-repair policy — no;
   each starts at `default_deny`.

### Deferred

1. The exact standing rubric wording and its version identifier — a
   design-review input for [#4495](https://github.com/viamin/paid/issues/4495),
   not a precondition for the policy above.
2. Which static analyzers attach to the security-hardening recipe — an
   evaluation output for [#4496](https://github.com/viamin/paid/issues/4496).
3. Whether the report surface should visualize the assessment's explanation
   and citations alongside a finding — a presentation decision for the
   recipe delivery issues.
4. Whether a future policy may let a schedule elect automatic repair — a
   separate design, out of scope here.

## What This Is Not

- Not a second maintenance capability — the family is a recipe catalog over
  the base maintenance lifecycle, not a new run type, report shape, or
  scheduling model.
- Not a provider of semantic judgment in code — the assessment is an
  `agent_harness` call; code validates structure and enforces the gates.
- Not an authorization to change source code — a scan still never mutates
  source code or opens a PR on its own, and automatic repair is inert until
  this policy is accepted.
- Not a blocking PR-review gate — advisory PR integration stays a later,
  separately approved decision owned by the base maintenance segment.
- Not a calibrated confidence system — this LLD defines an ordered standing
  and a comparison, not a probability.

## References

- [RDR-075 draft](../../rdrs/RDR-075-general-maintenance-runs.md) — the
  parent design; states that automatic repair requires a separately approved
  policy
- [`maintenance-runs` LLD](../maintenance-runs/maintenance-runs-design.md) —
  the run, report, finding-identity, tool, and repair-handoff contracts this
  family builds on
- [`agent-harness-integration` LLD](../agent-harness-integration/agent-harness-integration-design.md)
  — the boundary through which every application-level LLM call is made
- `app/services/llm/analyze_partial_closeout.rb` — the shipped precedent for
  a bounded semantic assessment with an explicit fail-closed `unknown` value
  and a structured response schema
