---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipes

> **Draft — pending design acceptance.** This reviewable contract extends the
> draft [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md) and the
> [`maintenance-runs`](../maintenance-runs/maintenance-runs-design.md) LLD. It
> authorizes no implementation, rollout, or automatic repair.

## Purpose

The optimization recipe family is a code-defined catalog for non-functional
maintenance investigations: performance, design/architecture, duplication,
security hardening, cost/resource efficiency, maintainability/readability,
and test coverage/quality. It owns catalog selection, scope semantics, honest
recipe evidence, semantic repair eligibility, and the separately approved
bounded automatic-repair policy RDR-075 requires. It consumes (and does not
redefine) the base maintenance run, report, finding identity, tools, and
repair-handoff contracts.

[#4493](https://github.com/viamin/paid/issues/4493) owns catalog/type-menu
delivery; [#4494](https://github.com/viamin/paid/issues/4494) the first three
recipes; [#4495](https://github.com/viamin/paid/issues/4495) assessment and
bounded auto-queue; [#4496](https://github.com/viamin/paid/issues/4496) staged
types. [#4492](https://github.com/viamin/paid/issues/4492) is tracking only
and owns no executable claim.

## Decision Provenance and Acceptance

The 2026-10-16 owner decisions recorded in [#4495](https://github.com/viamin/paid/issues/4495)
are the source for this policy: per-run off-by-default election, a configured
eligibility threshold, per-repair cost/time caps, checkout revalidation,
approved-finding scope, idempotency, and security default-deny. This LLD
expresses those decisions without changing their meaning: its ordered standing
is an uncalibrated semantic assessment, not a numeric confidence claim.

[#4636](https://github.com/viamin/paid/issues/4636) is the pending owner
decision on this precise HLD/LLD/EARS revision. Until an owner accepts that
revision and the canonical artifacts merge, this is preparation only: none of
#4493–#4496 may treat the recorded #4495 agreement as authorization to
implement, enable `maintenance_runs`, or auto-queue a repair.

## Catalog and Scope

The catalog is a code-defined registry, not a run enum or database column.
Each stable entry supplies its identifier, display name, investigation
description, default metric hints, recipe-definition pointer where present,
and repair standing. New entries require neither an enum change nor a
migration. UI, authenticated API, and MCP expose the same menu and
project-scoped start authorization. A missing or unmapped type starts a
custom-objective investigation; an unmapped value is retained in the immutable
run snapshot through retry.

Scope accepts paths, symbols, or a free-form natural-language target. A target
is resolved before coverage is claimed and the report records resolved scope
and exclusions. Scope bounds recommendations, not supporting evidence access:
callers, tests, framework entry points, and design documents may be inspected.
A proposed action beyond requested scope requires explicit human authorization
and cannot be automatically repaired.

## Recipe Execution and Honest Evidence

A recipe defines its objective, instructions, applicable collectors,
validation guidance, and metric hints. Tool use records analyzer name,
version, and configuration as provenance. If no applicable tool exists, the
prompt-first investigation is supported and the report discloses absent tool
evidence. Tool output is candidate evidence: duplication alone never proves
consolidation or deletion; findings record considered independence, callbacks,
and dynamic invocation. Findings retain the base contract for evidence,
counterevidence, proposed action, validation plan, and a disposition distinct
from raw tool confidence.

Recipes require evaluation evidence from at least one project other than Paid,
covering actionable findings, false positives, unresolved coverage, latency,
token/tool cost, recurring noise, and repair review outcomes before delivery
closes. Canonical finding identity and immutable occurrences remain owned by
the base maintenance segment.

## Semantic Repair-Eligibility Assessment

Eligibility is a semantic judgment and is produced through `agent_harness`
against a versioned structured rubric. Code validates its shape and enforces
authorization, budget, and idempotency gates; it never infers eligibility from
text, category strings, or raw analyzer scores. The result records canonical
finding, rubric version, standing, explanation, and citations.

The ordered standings are `strong`, `supported`, `exploratory`,
`insufficient`, and fail-closed `unknown`. They compare by order, never by an
invented numeric score. An absent, malformed, wrong-rubric, wrong-occurrence,
or materially stale assessment does not qualify and is reassessed when
evidence changes. This preserves #4495's configured threshold shape while
avoiding false claims that model probability is calibrated.

## Bounded Automatic Repair Policy

This policy is inert until accepted. Automatic repair is off by default and
is a per-run election captured at run start; it is never tenant-, project-, or
recipe-wide. A non-election is report-only. Schedules cannot elect it.

A finding is selected only if a `completed` report produced it, its assessment
meets the configured minimum standing (default `supported`), and its catalog
repair standing is `auto_eligible`. An election may only raise the minimum;
it cannot widen a type standing. Type standings change only through a separate
owner authorization recorded against the catalog. `partial`, `cancelled`, and
`budget_exhausted` reports dispatch nothing and record why; every report is
still delivered in full with manual selection available.

Auto-dispatch uses the unchanged base repair-handoff path and links report and
canonical finding. It revalidates evidence against a moved repair checkout,
surfaces failure, suppresses a duplicate queued/completed automatic repair for
the same canonical finding, carries explicit cost/time caps, preserves
evidence on exhaustion, and stays within the approved finding. Broader action
requires human authorization. The base `maintenance_runs` guard stops new
admissions/queues while retaining reports and in-flight repairs.

`security_hardening` is `manual_only` pending a dedicated accuracy and safety
review. Newly staged types are `default_deny` until separate owner
authorization. This is a preparation-only policy, not a rollout decision.

## Issue Mapping

| Issue | Owns |
| --- | --- |
| #4493 | Catalog, menu, snapshots, unmapped fallback, guard admission. |
| #4494 | First recipes, provenance, honest evidence, evaluation evidence. |
| #4495 | Assessment, election, dispatch, revalidation, idempotency, budgets. |
| #4496 | Staged types, security manual-only, test-quality reconciliation. |
| #4492 | Tracking only; no executable claim. |

## Decisions & Alternatives

| Decision | Chosen | Rationale |
| --- | --- | --- |
| Type representation | Code-defined catalog | Avoids migrations/enums and retains entry metadata. |
| Selection threshold | Ordered assessment standing | Model probabilities and analyzer scores are not calibrated repair authorization. |
| Type widening | Separate owner authorization | Per-run election cannot make a manual-only type automatic. |
| Default minimum | `supported` | Requires affirmative evidence without inventing a stronger evidence guarantee. |
| Dispatch timing | `completed` report only | Partial coverage must not silently support a repair. |
| Acceptance boundary | Explicit owner acceptance of this canonical revision | #4495 supplies policy provenance; #4636 decides whether this revision becomes implementation intent. |

## What This Is Not

- A second maintenance lifecycle, tool marketplace, or repair-handoff pathway.
- Semantic judgment implemented in application code.
- Authorization to mutate source, enable `maintenance_runs`, or roll out the
  family.
- A calibrated numeric confidence system or a blocking PR-review gate.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [`maintenance-runs` LLD](../maintenance-runs/maintenance-runs-design.md)
- [`agent-harness-integration` LLD](../agent-harness-integration/agent-harness-integration-design.md)
