---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipes

> **Draft — pending design acceptance.** This leaf extends the draft
> [`maintenance-runs`](../maintenance-runs/maintenance-runs-design.md) LLD and
> [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md). It is a
> reviewable prerequisite only: it authorizes neither implementation nor
> rollout.

## Purpose

Optimization recipes are non-functional maintenance investigations that help a
project contract duplication, maintainability, performance, security,
resource cost, architecture, and test-quality concerns without adding product
functionality. This segment owns the optimization catalog, selection and scope
semantics, honest evidence, semantic repair eligibility, and the separately
approved bounded automatic-repair policy required by RDR-075. It consumes the
base maintenance lifecycle, reports, finding identity, tool attachments, and
repair-handoff pathway; it does not duplicate them.

[#4493](https://github.com/viamin/paid/issues/4493) owns the catalog and menu;
[#4494](https://github.com/viamin/paid/issues/4494) owns the first recipes;
[#4495](https://github.com/viamin/paid/issues/4495) owns this bounded policy;
and [#4496](https://github.com/viamin/paid/issues/4496) owns staged types.
[#4492](https://github.com/viamin/paid/issues/4492) is tracking-only and owns
no executable claim.

## Catalog, Selection, and Scope

The catalog is a code-defined registry, presented as a type menu rather than a
run-contract enum. An entry has a stable identifier, display name, purpose,
metric hints, a recipe pointer where available, and a repair standing. Adding
a type is a catalog entry, never an enum migration. The initial entries are
`performance`, `design_architecture`, `code_duplication`,
`security_hardening`, `cost_resource_efficiency`,
`maintainability_readability`, and `test_coverage_quality`.

UI, authenticated API, and MCP expose equivalent selection and authorization.
No selection, or an unmapped selection, is a custom-objective maintenance run;
the latter is retained for report provenance rather than rejected. The chosen
type, objective, scope, guidance, limits, and recipe version are immutable
run-snapshot inputs retained over retries.

Scope may name paths, symbols, or a free-form natural-language target such as
a feature or page. A named target is resolved before coverage is claimed.
Scope bounds recommendations, not supporting evidence: callers, tests,
framework entry points, and design documents may be inspected to validate a
claim. A proposed action outside requested scope needs explicit human
authorization and is ineligible for automatic repair.

## Recipe Execution and Honest Evidence

Each recipe defines its objective, investigation instructions, applicable
evidence collectors, validation guidance, and metric hints. Tool provenance
(name, version, configuration) is reported when a tool applies; where it does
not, prompt-first investigation is a supported path and the report explicitly
states that no tool evidence was collected. Reports distinguish complete,
partial, cancelled, and budget-exhausted coverage under the base contract.

Analyzer output is candidate evidence, not a verdict. In particular,
similarity does not establish that code should be shared or deleted; a
duplication recommendation must address deliberate independence, framework
callbacks, and dynamic invocation. Every finding retains the base claim,
evidence, counterevidence, action, validation, and verification-disposition
records. Repeated scans reuse canonical finding identity and create a new
occurrence rather than duplicate repair work. Before a recipe closes, its
evaluation records findings, false positives, coverage limitations, latency,
token/tool cost, repeat noise, and repair outcomes on at least one non-Paid
project.

## Semantic Repair-Eligibility Assessment

Whether evidence supports automatic action is semantic judgment. It is made
through `agent_harness` using a versioned rubric, with a structured result
containing the canonical finding, rubric version, standing, explanation, and
citations. Code performs only structural validation and deterministic policy
enforcement; it must not infer eligibility from text, category strings, or raw
analyzer confidence.

The ordered standing is `strong`, `supported`, `exploratory`, `insufficient`,
or `unknown`. It is compared by order, never converted to a numeric score.
`unknown`, absent, malformed, unknown-rubric, wrong-occurrence, or materially
stale assessments fail closed. This preserves #4495's threshold shape without
pretending an LLM probability is calibrated: a configured minimum compares a
bounded semantic standing, not a model-produced number or tool score.

## Bounded Automatic Repair Policy

This policy stays inert until separately accepted. Automatic repair is an
off-by-default, per-run election captured at run start; it is never a tenant,
project, recipe, or schedule default. A non-electing run remains report-only.
A schedule cannot elect automatic repair because that would create the
prohibited standing default.

A finding qualifies only when all of these deterministic gates pass:

- Its assessment meets the configured minimum standing (default `supported`).
- Its catalog repair standing is `auto_eligible`; an election may narrow this,
  never widen `manual_only` or `default_deny`.
- The source report is `completed`; partial, cancelled, and budget-exhausted
  reports queue nothing and record that reason.
- The repair stays within the approved finding and carries explicit cost/time
  caps; exhausted runs preserve and report collected evidence.
- The repair checkout revalidates evidence when its revision moved; failures
  are visible and never silently dispatch stale work.
- No queued or completed automatic repair already exists for the canonical
  finding identity.

The complete report remains available and unselected findings remain manual.
Dispatch uses the unchanged base repair-handoff pathway and links source report
and finding identity. The base `maintenance_runs` guard remains default-off;
disabling it admits neither new optimization runs nor automatic repairs, and
does not cancel in-flight repairs or delete reports.

`security_hardening` is permanently `manual_only` pending a separately
authorized accuracy and safety review. Every newly staged type is
`default_deny` until its own owner authorization and evaluation evidence move
its standing. Security, cost/resource efficiency, design/architecture, and
test coverage/quality are the staged types; test quality reconciles with, and
does not duplicate, RDR-075's planned test-quality recipe.

## Issue Mapping

| Issue | Scoped deliverable |
| --- | --- |
| #4493 | Catalog, type menu, snapshot, unmapped fallback, guard admission. |
| #4494 | First recipes, honest evidence, provenance, false-positive cautions, evaluation. |
| #4495 | Assessment, election, thresholds, deterministic dispatch gates, budgets, revalidation, idempotency. |
| #4496 | Staged types, security manual-only enforcement, test-quality reconciliation. |
| #4492 | Tracking umbrella only; no executable claim. |

## Decisions & Alternatives

| Decision | Chosen | Alternative | Rationale |
| --- | --- | --- | --- |
| Type representation | Code-defined catalog | Enum or migration | Types remain extensible and unmapped values remain reportable. |
| Eligibility signal | Ordered `agent_harness` standing | Numeric model confidence | Semantic probabilities are not calibrated; code must not manufacture semantic judgment. |
| Threshold default | `supported` | `exploratory` or `strong` | It requires affirmative evidence without claiming the first recipes can always establish no counterevidence. |
| Auto-repair type authority | Catalog repair standing, changed by owner authorization | Run election overrides | A per-run election cannot weaken a safety property of a type. |
| Dispatch outcome | `completed` only | Any terminal report | Partial coverage cannot honestly support automatic action. |

## What This Is Not

- Not a second maintenance runtime, tool marketplace, or repair pathway.
- Not an implementation or rollout authorization; base acceptance and the
  #4604 live tool-handoff evidence remain independent prerequisites.
- Not automatic security repair or a calibrated confidence system.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [`maintenance-runs` LLD](../maintenance-runs/maintenance-runs-design.md)
- [`agent-harness-integration` LLD](../agent-harness-integration/agent-harness-integration-design.md)
