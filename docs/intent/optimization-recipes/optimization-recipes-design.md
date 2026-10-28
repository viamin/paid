---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipes

> **Draft — pending design acceptance.** Companion to
> [`docs/high-level-design.md`](../../high-level-design.md), the
> [`maintenance-runs`](../maintenance-runs/maintenance-runs-design.md) LLD it
> extends, and the draft [`RDR-075`](../../rdrs/RDR-075-general-maintenance-runs.md)
> design (Status: Draft). This LLD and its EARS specs are a reviewable contract
> produced for the human review gate; they are not accepted intent and authorize
> no implementation, no rollout, and no automatic repair.

## Purpose

Paid's general maintenance capability investigates a repository and reports
what it found. The optimization recipe family is the recipe catalog for
*contracting* audits: non-functional investigations that make a project more
efficient without adding functionality — duplication, maintainability,
performance, security hardening, cost, architecture, and test quality.

This LLD owns the optimization catalog and its type selection, the scope
semantics of an optimization run, the honest-evidence contract for optimization
recipes, the semantic repair-eligibility assessment, and the bounded
automatic-repair policy that RDR-075 requires to be approved separately before
any scan may queue repair work.

It does not own maintenance runs, reports, finding identity, tool attachment,
or the repair-handoff pathway itself. Those belong to the
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

Each catalog entry carries a stable identifier; display name and description;
default metric hints; a pointer to its underlying recipe when one exists; and a
**repair standing** that governs whether findings of the type may ever be
queued automatically.

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

Selection is presentation. The UI, authenticated API, and MCP surface expose
the same type menu and apply the same project-scoped start authorization. A
run with no type, or an unmapped type, starts as a custom-objective
investigation; the unmapped value is recorded and the selection alone never
fails a start. The selected type is in the immutable run snapshot alongside
objective, scope, guidance, and limits, and survives retries.

## Scope Contract

An optimization scope may be paths, symbols, or a free-form natural-language
target — a file, feature, or page in the application. There is no limit on the
breadth of a natural-language scope. Named targets are resolved before any
check claims coverage, and the report records resolved scope and exclusions,
distinct from the request.

Scope bounds **recommendations**, not **evidence access**. An investigation
may inspect callers, tests, framework entry points, and design documents
outside the requested scope to validate a claim. A proposed action extending
beyond the requested scope requires explicit human authorization and is never
eligible for automatic repair.

## Recipe Execution and Honest Evidence

A recipe supplies an objective, investigation instructions, applicable evidence
collectors, validation guidance, and default metric hints. Where a tool
attaches, its name, version, and configuration are provenance on the finding
and report. Where no tool applies, the investigation completes prompt-first
and says so; this supported path is not degraded. The completed-checks list,
not the presence of findings, distinguishes incomplete coverage.

Analyzer output is candidate evidence, not a verdict. Similarity alone does
not establish code should be shared: a finding must record deliberate
independence, framework callbacks, and dynamic invocation considered before
recommending consolidation or deletion. Each finding carries the base contract:
category, affected locations/symbols, claim, supporting and counterevidence,
proposed action, validation plan, and a verification disposition distinct from
raw tool confidence. Repeated scans use the base canonical finding identity
and create new occurrences rather than duplicate repair work.

Before a recipe delivery closes, its evaluation evidence is recorded against at
least one project outside Paid: actionable findings, false positives,
unresolved coverage, latency, token/tool cost, repeated-finding noise, and
repair review outcomes.

## Semantic Repair-Eligibility Assessment

A repair-eligibility assessment decides whether a finding's evidence supports
applying its proposed action automatically. This semantic judgment belongs to
an `agent_harness` call against a versioned rubric, with a structured result.
Application code validates the result's structure and enforces the policy
gates; it never infers the judgment from text, title, category, or a raw
analyzer confidence score.

The result records the canonical finding, rubric version, standing,
explanation, and citations. Its bounded ordered standings are:

| Standing | Meaning |
| --- | --- |
| `strong` | Evidence directly supports the proposed action, with no material counterevidence. |
| `supported` | Evidence supports the proposed action. |
| `exploratory` | Evidence suggests the action, but not enough to justify an automatic change. |
| `insufficient` | Evidence does not support the action. |
| `unknown` | The assessment could not reach a standing. |

Standings are compared by order, never a numeric score. `unknown`, an absent
or malformed assessment, an unknown rubric, or an assessment for another
occurrence fails closed. When recorded evidence materially changes, the
assessment no longer applies and must be redone.

This reconciles #4495's confidence threshold with Zero Framework Cognition:
the configured-minimum shape is retained, but a calibrated number is not
invented. The ordered, bounded, human-readable standing is the threshold input.

## Bounded Automatic Repair Policy

RDR-075 says automatic repair requires a separately approved policy. This
section is that candidate policy. It is inert until accepted and authorizes no
implementation.

Automatic repair is opt-in, per run, and off by default. Its election is
captured at run start on the same surfaces that start a run; it is never a
tenant-, project-, or recipe-wide default. A run without it is report-only. A
schedule cannot elect it: a schedule-level election would be a recipe default
by another name.

A finding is selected only if its assessed standing meets the configured
minimum and its type permits automatic repair. The default minimum is
`supported`. A run election can require a stricter standing but never widen a
type's repair standing. Catalog repair standings are:

| Standing | Automatic repair |
| --- | --- |
| `auto_eligible` | May queue once standing and budget gates pass. |
| `manual_only` | Reported for manual selection only. |
| `default_deny` | Reported only pending a separate owner authorization. |

`security_hardening` is `manual_only` until a dedicated accuracy and safety
review accepts automatic hardening repairs. Newly staged types start
`default_deny`; only a separate owner authorization recorded against the
catalog changes a type standing.

The full report is delivered whatever is selected. Dispatch occurs only from a
`completed` report; `partial`, `cancelled`, and `budget_exhausted` reports queue
nothing and record why. Dispatch uses the base repair-handoff unchanged and
links back to its report and canonical finding. If the repair target moved,
evidence is revalidated in the repair checkout; failure is visible. A canonical
finding identity with a queued or completed automatic repair is not dispatched
again. Each repair has explicit cost/time caps; exhaustion preserves and reports
collected evidence. Repair scope stays bounded to the approved finding.

The base `maintenance_runs` guard controls this family. With it off, no new
maintenance run or automatic repair is admitted; active repairs are not
cancelled and reports are not deleted.

## Staged Optimization Types

After the first three recipes produce evaluation evidence, #4496 delivers:
security hardening (manual-only), cost/resource efficiency (prompt-first),
design/architecture (prompt-first proposed actions), and test coverage/quality
(reconciled with RDR-075's planned test-quality recipe). Each catalog entry
carries its metadata, evidence collectors, and metric hints; none needs an enum
change or migration.

## API, UI, and MCP Parity

The type menu, automatic-repair election, and standing/cap defaults are
equivalent on UI, authenticated API, and MCP, each with the same project-scoped
authorization.

## Issue Mapping

| Issue | Owns |
| --- | --- |
| [#4493](https://github.com/viamin/paid/issues/4493) | Catalog, type menu, snapshot persistence, unmapped fallback, guard behavior. |
| [#4494](https://github.com/viamin/paid/issues/4494) | First recipes, provenance, false-positive cautions, prompt-only honesty, finding identity, evaluation evidence. |
| [#4495](https://github.com/viamin/paid/issues/4495) | Assessment, election, thresholds, dispatch, revalidation, idempotency, budgets, standings, guard behavior. |
| [#4496](https://github.com/viamin/paid/issues/4496) | Staged types, security manual-only enforcement, test-quality reconciliation, evaluation. |
| [#4492](https://github.com/viamin/paid/issues/4492) | Tracking umbrella only; no executable claim. |

## What This Is Not

- Not a second maintenance capability or a provider of semantic judgment in code.
- Not authorization to change source code: a scan does not mutate source or
  open a PR, and automatic repair remains inert pending acceptance.
- Not a blocking PR-review gate or a calibrated confidence system.

## References

- [RDR-075 draft](../../rdrs/RDR-075-general-maintenance-runs.md)
- [`maintenance-runs` LLD](../maintenance-runs/maintenance-runs-design.md)
- [`agent-harness-integration` LLD](../agent-harness-integration/agent-harness-integration-design.md)
- `app/services/llm/analyze_partial_closeout.rb` — bounded semantic-assessment precedent.
