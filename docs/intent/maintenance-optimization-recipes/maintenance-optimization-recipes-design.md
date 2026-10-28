---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Maintenance Optimization Recipes and Bounded Repair Policy

> **Draft — pending design acceptance.** This leaf refines the draft
> [general maintenance runs LLD](../maintenance-runs/maintenance-runs-design.md)
> and RDR-075. It records a reviewable prerequisite for the #4492 optimization
> family; it authorizes no runtime behavior, feature-flag enablement, or
> rollout. The base maintenance acceptance and its RDR-073 evidence dependency
> remain independent prerequisites.

## Purpose

Optimization recipes let a project owner select a curated maintenance
investigation type while retaining a free-text, report-only investigation
path. The same policy may, only when an owner elects it for one run, create
a bounded repair handoff after that report completes. This is a narrow
exception to the base maintenance default that scans do not mutate source
code or create repair work without a user selection.

The policy exists to make the exception reviewable: it must preserve the
maintenance report's honest evidence, the M04 repair pathway's scope and
revalidation guarantees, and Paid's separation of semantic judgment from
deterministic authorization and resource controls.

## Catalog and Recipe Selection

The optimization catalog is data-backed recipe content, not an enum or a
database-migration namespace. Each entry has a stable key, display name,
description of the investigation it supports, default metric hints, objective,
investigation instructions, applicable evidence collectors, validation
guidance, and a recipe version. Adding a type is a catalog entry change.

The initial catalog is:

| Catalog type | Initial delivery | Scoped implementation issue |
| --- | --- | --- |
| Performance | Prompt-first; disclose unavailable or incomplete tool coverage | #4494 (OPT-02) |
| Design / Architecture | Staged prompt-first recommendation recipe | #4496 (OPT-04) |
| Code Duplication | Tool-assisted where a validated collector is available | #4494 (OPT-02) |
| Security Hardening | Staged report-only and manual-repair selection | #4496 (OPT-04) |
| Cost / Resource Efficiency | Staged prompt-first recipe | #4496 (OPT-04) |
| Maintainability / Readability | Tool-assisted where a validated collector is available | #4494 (OPT-02) |
| Test Coverage & Quality | Staged recipe reconciled with RDR-075 test-quality work | #4496 (OPT-04) |

#4493 (OPT-01) owns catalog registration and equivalent UI/API/MCP selection.
#4494 (OPT-02) owns the first three recipes and their evaluation evidence.
#4495 (OPT-03) owns the selected automatic-handoff policy below. #4496
(OPT-04) owns the staged remaining recipes. #4492 is a tracking umbrella,
not an executable prerequisite or authority for runtime behavior.

A start request may select one catalog key and combine it with free-text
guidance and optional scope under MAINT-011 through MAINT-015. An unmapped
key degrades to a custom-objective run rather than failing admission. The
resolved catalog entry and policy revision are snapshotted at run start and
remain unchanged across retries.

## Scope and Honest Evidence

Scope bounds recommendations and repair changes, not the supporting evidence
an investigation may inspect. Collectors and the assessing agent may inspect
callers, tests, framework entry points, and design records outside named scope
to verify a claim. A recommendation that reaches outside requested scope
explains that fact; a repair that would do so requires explicit human
authorization and cannot be automatically handed off.

Each recipe uses the maintenance report and occurrence contract. Tool output,
collector versions/configuration, coverage limitations, counterevidence,
and incomplete checks remain visible. Prompt-first is a supported evidence
mode, not a claim that a tool ran. No missing collector, failed collector, or
budget-limited analysis may be represented as a clean result.

## Semantic Assessment and Deterministic Gates

`agent_harness` performs semantic assessment of collector output, repository
intent, and counterevidence. Its structured assessment records the claim,
evidence and counterevidence considered, a policy-defined ordered confidence
level, proposed bounded scope, validation plan, and a reasoned eligibility
recommendation. Application code must not derive semantic eligibility from
keywords, raw analyzer scores, or a locally calibrated numeric confidence.

The elected policy snapshots an ordered confidence vocabulary and minimum
level with the run. This is an ordinal decision aid for an agent assessment,
not a calibrated probability or a guarantee that a repair is correct. Code
may deterministically compare the returned level to the snapshotted order, but
the level's meaning is supplied by the `agent_harness` assessment. Raw tool
confidence remains evidence only and is never silently substituted for this
assessment.

After report completion, code performs only structural and policy gates before
creating an M04 repair request: `maintenance_runs` remains admitted, the
per-run election exists, the initiating user remains authorized for the repair
pathway, the assessment meets the snapshotted level, the finding is not a
security category, the proposed scope is contained by the finding, explicit
cost/time limits are present, the finding is fresh or has revalidated
successfully, and no repair already exists for the canonical finding identity
and policy revision. A failed gate creates a visible non-dispatch outcome with
its evidence; it never silently drops a qualifying finding.

## Bounded Automatic Repair

Automatic handoff is opt-in and off by default. It is a per-run election in
the UI, authenticated API, and MCP start contracts, never a tenant-wide,
schedule-wide, catalog-wide, or recipe-default setting. Omission is exactly
the report-only behavior defined by MAINT-073.

An election snapshots the minimum confidence level, explicit per-repair
cost/time limits, and policy revision. Qualifying findings use the existing
M04 bounded issue or PR-creation pathway and retain report/finding provenance.
The repair scope cannot expand beyond the approved finding without a human
authorization. Repeated occurrences with the same canonical finding identity
must not create duplicate repair work.

If the repair checkout no longer matches the report revision, the finding is
revalidated before its recommendation can be applied. Revalidation failure,
inconclusive evidence, or an unavailable target produces a visible blocked or
failed-revalidation outcome and preserves evidence. It does not authorize an
old recommendation.

Security Hardening findings are manual-only. They are excluded from automatic
handoff until a distinct security-policy review accepts an extension; neither
this policy nor catalog registration supplies that authorization. Disabling
`maintenance_runs` stops new automatic handoffs while retaining reports and
leaving already-created repair runs under their normal lifecycle.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Catalog representation | Extensible recipe catalog with a custom-objective fallback | Enum/migration per type; require a catalog key | Recipe content changes independently of persistence shape, and free-text maintenance questions remain first-class. |
| Semantic confidence | `agent_harness` returns a policy-defined ordinal assessment; code compares only its declared order | Raw tool score; code-derived numeric calibration | Meaning-based quality judgment belongs to the agent. Deterministic code can enforce a declared policy without pretending a score is calibrated. |
| Automatic handoff authority | Per-run owner election plus deterministic gates and the existing M04 pathway | Tenant/recipe default; scan mutates source directly | The election is explicit and revocable, while M04 retains repair authorization, scope, and revision protections. |
| Security repair | Manual-only pending a separate policy | Include security in OPT-03 auto-queue | Security findings need a dedicated authorization decision rather than inheriting a general optimization policy. |

## Acceptance and Delivery Boundaries

This LLD and its specs are preparation artifacts. Before #4493–#4496 begins,
the project owner must explicitly accept the precise catalog, ordinal
confidence-policy, and automatic-handoff revisions in this leaf together with
the corresponding base maintenance revisions. That acceptance must be recorded
through the authorized review workflow and the canonical artifacts merged.

This preparation does not close #4492, enable `maintenance_runs`, satisfy the
RDR-073 tool-handoff evidence, or remove base RDR-075 acceptance as an
independent dependency. While acceptance is pending, a preparation PR must
track #4636 and remain on review hold with an Inbox decision requesting
acceptance or revisions.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [General maintenance runs LLD](../maintenance-runs/maintenance-runs-design.md)
- [General maintenance EARS](../maintenance-runs/maintenance-runs-specs.md)
- #4492 tracking umbrella; #4493 OPT-01; #4494 OPT-02; #4495 OPT-03; #4496 OPT-04
- #4635 base maintenance acceptance prerequisite; #4636 optimization-policy prerequisite
