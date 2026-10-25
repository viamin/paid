---
parent: PAID
prefix: OPT
---

# Low-Level Design: Optimization Recipes and Bounded Repair Policy

> **Preparation draft — owner acceptance required.** This extension refines the
> draft RDR-075 maintenance contract; it neither accepts RDR-075 nor enables
> maintenance or repair runtime behavior. The `maintenance_runs` guard remains
> default-off. This document and its EARS companion require an explicit owner
> acceptance record and merge before any implementation work begins.

## Purpose

Optimization recipes give an authorized user a curated way to request a
report-only maintenance investigation. They reuse the maintenance run, report,
finding, evidence, repair-handoff, and rollout contracts; they do not create a
second maintenance lifecycle. The initial catalog is Performance, Design /
Architecture, Code Duplication, Security Hardening, Cost / Resource Efficiency,
Maintainability / Readability, and Test Coverage & Quality.

The catalog is data-driven: a recipe entry supplies its display text,
investigation instructions, evidence-collector applicability, validation
guidance, and metric hints. Adding a type is an entry change, not an enum or
migration. A missing or unrecognized type falls back to a free-text custom
objective and is recorded as such; it never prevents a valid maintenance run.

## Relationship to the Maintenance Contract

This segment consumes `MAINT-001`–`MAINT-045` and `MAINT-070`–`MAINT-073`.
The base contract remains authoritative for project authorization, pinned
revisions, scope, immutable evidence, coverage disclosure, finding identity,
repair provenance, and stale-finding revalidation. In particular, a recipe
selection does not widen a repair beyond the finding's approved scope.

Optimization is report-only by default. The only proposed exception is the
per-run auto-queue election below. It is not a scan-side repair action: it is
a pre-authorized request to use the existing bounded M04 repair pathway after
the report exists, and it must pass every authorization and revalidation gate
at the point that pathway acts. Without a valid election, an omitted field, or
any failed gate, findings remain manual-selection-only.

## Recipe Selection and Evidence

The project UI, authenticated API, and MCP surface expose the same curated
menu, free-text composition, authorization, and snapshot behavior. A selected
recipe key and version are captured with the maintenance run's objective,
scope, guidance, revision, tool configuration, and limits; retries retain the
snapshot. Recipe scope bounds recommendations, not supporting inspection, and
reports must identify any evidence outside the requested scope plus all
incomplete or unavailable checks.

Recipes may be tool-assisted or prompt-first. Tool output is candidate
evidence, never a repair authorization or proof that code should change. The
agent performs semantic assessment only through `agent_harness`, using a
structured response tied to supplied evidence pointers. Paid code validates
the response shape and enforces authorization, scope, revision, budget,
idempotency, and feature-gate policy; it must not infer semantic eligibility
from keywords, score heuristics, titles, or analyzer output.

The confidence threshold elected for auto-queue is a policy input, not a new
calibrated semantic model. Its scale, calibration, and meaning are owned by
the structured assessment contract selected at acceptance; this design does
not invent a numeric interpretation. Once that contract supplies a valid
assessment value, deterministic code may compare it with the run-start
snapshot threshold. It must retain the assessment and evidence references in
the report, and it must never replace the report's raw tool confidence.

## Bounded Auto-Queue Policy

An authorized user may elect auto-queue only while starting an optimization
run. The election is opt-in, off by default, and captures the threshold and
explicit per-repair cost/time limits with the immutable run snapshot. It is
not a tenant default, recipe default, schedule default, or a later report
toggle. Omitting it produces exactly the report-only M04 behavior.

After a terminal report, a finding may enter the existing repair pathway only
when all of these deterministic gates hold:

1. `maintenance_runs` is enabled for new admissions and the stored election is
   valid for this report and canonical finding.
2. The agent-harness assessment structurally identifies the finding as eligible
   and its declared confidence meets the stored threshold under the accepted
   assessment contract.
3. The finding category is not Security Hardening. Security findings remain
   report-only and manual-selection-only until a separate policy explicitly
   authorizes automatic security repair.
4. The existing M04 pathway authorizes the requested repair target, preserves
   the selected finding's bounded scope and report/finding provenance, and
   accepts the per-repair budget snapshot.
5. The idempotency record for the canonical finding and election has not
   already created or reserved repair work. Repeated occurrences must link to
   the existing work rather than create duplicate repair runs.

The repair pathway revalidates the finding against its repair checkout whenever
the target revision differs from the source report. A stale or failed
revalidation blocks application visibly and preserves the report, election,
and gate result for manual action; it never silently applies, retries without
the normal retry policy, or discards the finding. Budget exhaustion likewise
preserves evidence and reports the existing maintenance outcome honestly.
Disabling maintenance admission stops future auto-queues but neither cancels
already-created repair runs nor deletes reports.

## Decisions and Alternatives

| Decision | Chosen policy | Rejected alternative | Rationale |
| --- | --- | --- | --- |
| Catalog representation | Data-driven recipe entries | Type enum/migration | Recipes can grow without schema churn. |
| Semantic assessment | Structured `agent_harness` assessment plus deterministic gates | Keyword or analyzer-score rules in Paid | Meaning belongs to the model; policy enforcement belongs to code. |
| Auto-queue authority | Per-run, start-time, explicit election | Tenant-wide or recipe-default enablement | Preserves owner control and report-only default. |
| Duplicate prevention | Canonical finding plus election idempotency | One repair per report occurrence | Recurrence must not multiply repair work. |
| Security findings | Manual-only | Inherit general auto-queue | Security repair needs separately approved authority. |

## Tracks

This is a preparation track, not rollout authorization. Owner acceptance must
identify this exact revision and the OPT claims below, then the accepted
canonical artifacts must merge before any track is executable. Until then,
the concrete Inbox decision is: **accept or amend the optimization recipe and
bounded-repair policy; keep `maintenance_runs` off and do not implement or
auto-queue repairs.**

| Track | Claims | Delivery issue | Status |
| --- | --- | --- | --- |
| Catalog and surfaces | OPT-001–OPT-004 | [#4493](https://github.com/viamin/paid/issues/4493) | Prerequisite pending acceptance |
| First recipes and honest evidence | OPT-010–OPT-014 | [#4494](https://github.com/viamin/paid/issues/4494) | Prerequisite pending acceptance |
| Opt-in bounded auto-queue | OPT-020–OPT-029 | [#4495](https://github.com/viamin/paid/issues/4495) | Prerequisite pending acceptance |
| Staged recipes and security exclusion | OPT-030–OPT-033 | [#4496](https://github.com/viamin/paid/issues/4496) | Prerequisite pending acceptance |

[#4492](https://github.com/viamin/paid/issues/4492) is tracking and final
acceptance only; it is not an executable prerequisite deliverable. This
segment also depends independently on base-maintenance acceptance (#4635),
the RDR-075 tool-handoff evidence (#4604), and the relevant M01–M04 delivery
contracts. Neither a closed optimization child nor this preparation artifact
accepts or rolls out base maintenance.

## Boundaries

- No maintenance scan mutates source code or opens a PR as a side effect.
- No provider API is called outside `agent_harness` for semantic assessment.
- No auto-queue policy authorizes merge, bypasses review/CI/security policy,
  expands scope, or changes the `maintenance_runs` rollout guard.
- Cost/resource, architecture, and test-quality recipes are report-first;
  their evidence limits remain visible. Security repair remains manual-only.
