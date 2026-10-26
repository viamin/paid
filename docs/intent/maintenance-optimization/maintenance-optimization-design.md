---
parent: PAID
prefix: OPT
---

# Low-Level Design: Maintenance Optimization Recipes

> **Draft — pending human design acceptance.** Tracks [#4492](https://github.com/viamin/paid/issues/4492) without closing its tracking umbrella and supplies the design prerequisite in [#4636](https://github.com/viamin/paid/issues/4636). It refines the draft [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md) maintenance contract; it neither accepts RDR-075 nor authorizes runtime behavior, rollout, or automatic repair.

## Purpose

The optimization recipe family lets a project owner request a contracting
maintenance audit from a curated type menu while preserving RDR-075's
report-first maintenance model. A run can recommend changes broadly enough to
evaluate the requested concern, but a repair remains bounded to a selected
finding and the existing repair pathway.

This leaf owns the optimization catalog, recipe selection, assessment contract,
and the narrowly pre-authorized auto-queue policy. It consumes the maintenance
run lifecycle, report/finding identity, repair handoff, feature guard, and
tool-attachment contracts from `maintenance-runs`; it does not change their
ownership or create a second execution path.

## Catalog and Recipe Selection

The initial code-defined catalog contains these presentation types:

- Performance
- Design / Architecture
- Code Duplication
- Security Hardening
- Cost / Resource Efficiency
- Maintainability / Readability
- Test Coverage & Quality

An entry supplies its display name, audit description, default metric hints,
and an optional underlying recipe reference. A catalog entry is extensible
configuration, not a persisted enum: adding a type adds an entry and recipe
definition, not a schema migration or a new maintenance goal. A missing or
unmapped selection becomes a custom-objective maintenance run; it is never a
start error.

The UI, authenticated API, and MCP start surfaces expose equivalent catalog
selection and authorization. Type selection composes with optional natural
language scope and guidance, and the selected entry, resolved recipe, and
recipe version are snapshotted with the maintenance run and retained by a
retry. Runs remain valid without a type selection.

Scope bounds recommendations, not supporting investigation. A recipe may
inspect callers, tests, entry points, and design context outside the requested
scope when that evidence is necessary, and must disclose that inspection and
any recommendation beyond the requested scope. A repair has the narrower
scope of its approved finding; an expansion requires explicit human
authorization.

## Assessment and Evidence

Collectors and prompt-first investigation propose candidates and preserve raw
tool output, provenance, coverage, and counterevidence under the maintenance
report contract. An `agent_harness` assessment determines the semantic claim,
its evidence and counterevidence, proposed action, verification disposition,
and policy-compatible assessment-confidence value. No controller, job, or
catalog code infers semantic suitability from keywords, locations, tool scores,
or a numerical heuristic.

Assessment confidence is an agent-produced selection field, not a calibrated
probability or a claim of measured repair accuracy. Its representation and
threshold comparison contract are supplied by the `agent_harness` structured
response schema and snapshotted policy. Deterministic code may validate the
response shape and compare that field to the elected threshold, but must not
assign, transform, or reinterpret semantic confidence. Raw tool confidence
remains distinct from the assessment.

Reports remain honest: a prompt-first recipe identifies that no tool check ran;
missing, failed, truncated, or unavailable planned checks retain the existing
partial-coverage outcome. Every finding, including a finding excluded from
automatic selection, remains visible for manual repair selection.

## Bounded Automatic Repair Policy

An owner may elect auto-queue only when starting an individual optimization
run. The election is absent by default and is never a tenant-wide, catalog, or
recipe default. The run snapshots the elected assessment-confidence threshold
and explicit cost/time limit for each potential repair. Omitted election is
exactly report-only maintenance behavior.

After a report produces a qualifying finding, code may dispatch a repair only
through the existing M04 repair handoff and only when all deterministic gates
pass:

1. the maintenance feature guard permits new admissions and the actor was
   authorized to elect repair creation at run start;
2. the run's snapshotted election is enabled, the structured assessment meets
   its snapshotted threshold, and the finding category is eligible;
3. the repair uses the snapshotted per-repair cost and time caps and remains
   within the finding's approved scope;
4. evidence is revalidated against the repair checkout when its target revision
   differs from the source report; a failed or unavailable revalidation is
   visible and cannot silently authorize or discard the repair; and
5. no repair work already exists for the same canonical finding identity and
   selected source/report policy, so repeated occurrences cannot create a
   duplicate repair.

Security Hardening is ineligible for auto-queue. Security findings remain
report-only with manual repair selection until a dedicated accuracy and safety
policy explicitly authorizes a narrower behavior. Disabling the maintenance
guard prevents new auto-queues but does not cancel active repair runs or erase
reports. Budget exhaustion preserves collected evidence through the existing
maintenance and repair contracts.

## Delivery Map

| Deliverable | Scoped intent | Execution dependency |
| --- | --- | --- |
| [#4492](https://github.com/viamin/paid/issues/4492) | Tracking umbrella and final family audit only | Not an executable prerequisite or source of runtime authorization |
| [#4493](https://github.com/viamin/paid/issues/4493) | Catalog entries, curated menu, custom-objective fallback, snapshots, equivalent start surfaces | Accepted RDR-075; M01 (#4328); this accepted leaf |
| [#4494](https://github.com/viamin/paid/issues/4494) | Duplication, maintainability, and performance recipes; honest prompt-first/tool evidence | #4493, M02 (#4329), M03 (#4330), and evaluation evidence |
| [#4495](https://github.com/viamin/paid/issues/4495) | Per-run opt-in auto-queue election and deterministic bounded-repair gates | #4493, M04 (#4331), and this accepted policy |
| [#4496](https://github.com/viamin/paid/issues/4496) | Staged security, cost, architecture, and test-quality recipes; security remains manual-only | #4494, #4495, and per-stage evaluation evidence |

Every implementation task independently depends on accepted base maintenance
intent and its listed maintenance milestones. Neither the tracking umbrella's
closure nor this preparation artifact enables a rollout.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- |
| Catalog representation | Code-defined extensible entries with optional recipe references | Database enum; project-admin authoring UI | A curated v1 menu needs stable presentation and recipe linkage without turning a selection into a migration or expanding administration scope (#4493). |
| Recommendation versus repair scope | Broad evidence inspection is permitted; repairs remain finding-bounded | Restrict all evidence to requested files; permit broad repair after a broad audit | Audit claims need callers and framework context, while repair authority needs a precise, reviewable boundary (RDR-075). |
| Semantic confidence | Structured `agent_harness` assessment field compared by a deterministic snapshot gate | Controller heuristics; calibrated probability asserted by application code | Meaning belongs to the agent; code can enforce policy but has no evidence here for numerical calibration. |
| Automatic repair | Per-run opt-in election, default off, with threshold, budgets, revalidation, and idempotency | Recipe-wide default; scan-side mutation; tenant-wide setting | Preserves the owner-approved #4495 policy without broadening RDR-075's report-only default. |
| Security repair | Manual selection only | Include security in the auto-queue policy | Security false positives and blast radius require a separate accuracy/safety authorization (#4496). |

## Acceptance and Rollout Boundary

Human acceptance must confirm this LLD and `OPT-*` specs before implementation
begins. Until then, [#4636](https://github.com/viamin/paid/issues/4636) remains
open as a preparation item with this Inbox decision: **accept or request
revision of the catalog, assessment-confidence, and auto-queue policy as one
design package; do not authorize implementation or rollout by accepting the
preparation PR alone.**

This is documentation-only. Runtime work remains behind RDR-075's
`maintenance_runs` default-off guard and its independent acceptance and
maintenance-milestone dependencies. No artifact here creates a feature flag,
queues a repair, or changes a running scan.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [maintenance-runs LLD](../maintenance-runs/maintenance-runs-design.md) and
  [EARS](../maintenance-runs/maintenance-runs-specs.md)
- [#4492](https://github.com/viamin/paid/issues/4492), [#4493](https://github.com/viamin/paid/issues/4493), [#4494](https://github.com/viamin/paid/issues/4494), [#4495](https://github.com/viamin/paid/issues/4495), and [#4496](https://github.com/viamin/paid/issues/4496)
