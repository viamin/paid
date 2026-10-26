---
parent: PAID
prefix: OPT
---

# Low-Level Design: Optimization Recipes and Bounded Repair Policy

> **Draft — pending owner acceptance.** This leaf refines the draft
> [general-maintenance LLD](../maintenance-runs/maintenance-runs-design.md)
> and [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md). It is a
> preparation artifact for #4493–#4496, not acceptance of RDR-075, runtime
> authorization, or rollout. The product-owner agreement recorded in #4495 is
> evidence for this draft; explicit acceptance of these precise artifacts is
> still required through #4636.

## Purpose

Optimization recipes let an owner choose a curated kind of report-only
maintenance investigation while retaining the base maintenance free-text
question path. The family covers performance, design/architecture, code
duplication, security hardening, cost/resource efficiency,
maintainability/readability, and test coverage/quality. A catalog is an
extensible collection of recipe entries, not an enum or a second run type.

This leaf also owns the separately proposed, narrow exception to the base
manual repair-selection rule: a user may opt in at the start of one
optimization run to automatically queue qualified, bounded repair work after
its report completes. The exception does not alter the base rule for any run
that omits the election, and security findings remain manual-only until a
separate policy authorizes them.

## Recipe Catalog and Selection

Each catalog entry has a stable key, display name, description, objective,
investigation instructions, applicable evidence collectors, validation
guidance, metric hints, and version. Recipe content composes with the
maintenance-run snapshot defined by MAINT-015; it does not change the
maintenance lifecycle, tool attachment contract, or `maintenance_runs`
rollout guard.

The initial catalog keys are `performance`, `architecture`, `duplication`,
`security_hardening`, `cost_efficiency`, `maintainability`, and
`test_quality`. Adding a later type is a catalog entry and recipe version,
not an enum migration. UI, authenticated API, and MCP expose the same
selection contract and authorization as MAINT-010–MAINT-011. A selected entry
composes with optional scope and guidance. An absent selection leaves the
free-text path unchanged; an unmapped submitted value is recorded as a
custom-objective run rather than rejected.

Recipe scope bounds recommendations, not supporting inspection. Assessment
may inspect callers, tests, framework entry points, and intent outside the
requested scope when needed to assess a claim, and must disclose that support
and all coverage limits. A proposed repair remains bounded to the selected
finding; any expansion beyond it needs explicit human authorization through
the base repair pathway.

## Evidence and Semantic Assessment

Evidence collectors produce bounded, provenance-bearing observations. A
collector's raw score, heuristic, or lack of result is evidence only; it does
not itself establish a recommendation, repair eligibility, or a clean report.
Missing, unavailable, failed, or truncated collectors follow MAINT's partial
coverage contract. Prompt-first recipes are valid where no credible collector
applies, but their report must state that limitation.

`agent_harness` performs the semantic assessment of observations, repository
context, counterevidence, scope, and validation plan. Its structured result
records the claim, supporting and contrary evidence, coverage limitations,
verification disposition, and whether the finding satisfies the run's
selected auto-queue confidence criterion. This is an AI judgment over the
specific finding, not a framework-owned calibrated numerical score. The
system snapshots the selected criterion as policy input and treats the
structured result as data for later audit; it does not infer eligibility from
keywords, raw tool scores, title text, or a locally invented confidence
formula.

Code remains responsible for structural validation of that result and for all
policy and state decisions: authorization, guard admission, category
exclusion, explicit budgets, revalidation, idempotency, and durable
provenance. This split preserves Zero Framework Cognition while keeping
side-effecting decisions deterministic and reviewable.

## Per-Run Bounded Auto-Queue

Auto-queue is an optional election captured immutably when an authorized user
starts an optimization run. It is default-off, never a tenant-wide or recipe
default, and has equivalent UI, API, and MCP admission. The election snapshots
the confidence criterion and explicit cost and time limits that every queued
repair will receive. Omitting it preserves the report-only/manual-selection
behavior of MAINT-070–MAINT-073 exactly.

After a report completes, the deterministic admission gate may request the
existing M04 repair pathway only when all of the following are true:

1. `maintenance_runs` remains enabled for new admission and the original
   per-run election is present.
2. The finding is non-security, open, and has a structurally valid semantic
   assessment that satisfies the snapshotted confidence criterion.
3. The finding's report evidence and repair checkout are revalidated when the
   target revision has moved, using MAINT-071; a failed or unavailable
   revalidation is visible and creates no repair.
4. The queued repair receives the election's explicit cost and time limits and
   retains collected evidence if either is exhausted.
5. Existing canonical-finding identity and repair lineage show no already
   queued or created automatic repair for that finding. Repeated occurrences
   therefore cannot create duplicate repair work.

The repair is created only through the existing authorized M04 issue or
PR-creation pathway and links to its source report, finding occurrence, and
canonical finding. Disabling the maintenance guard stops future admissions and
auto-queues without deleting reports or cancelling active repair work.
Security-hardening findings are excluded before this gate: they remain in the
report and are available only for explicit manual selection until a dedicated
security-repair policy is accepted.

## Delivery Mapping

| Deliverable | Scoped claims | Boundary |
| --- | --- | --- |
| #4493 OPT-01 catalog and type menu | OPT-001–OPT-004 | Catalog selection and run snapshot only; no recipe implementation or repair dispatch. |
| #4494 OPT-02 first recipes | OPT-010–OPT-014 | Duplication, maintainability, and performance evidence and honest reports. |
| #4495 OPT-03 bounded auto-queue | OPT-020–OPT-024 | Per-run opt-in authorization and deterministic repair gates only. |
| #4496 OPT-04 staged recipes | OPT-015–OPT-019 | Security, cost, architecture, and test-quality recipes; security stays manual-only. |
| #4492 umbrella | None | Tracking and final coordination; it is not an executable prerequisite or implementation deliverable. |

Each implementation remains independently blocked by base RDR-075 design
acceptance and its runtime prerequisites. This preparation neither closes nor
depends on closing #4492 or the runtime children.

## Decisions & Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Recipe representation | Extensible catalog entries with versioned recipe content | Enum-backed type migration; free text only | Entries can evolve without schema churn while preserving the free-text maintenance objective. |
| Recommendation assessment | Structured semantic assessment through `agent_harness`; raw scores remain evidence | Local score formula; collector score as authorization | Meaning, counterevidence, and repository intent require semantic judgment; code can enforce the resulting bounded policy without pretending to calibrate that judgment. |
| Automatic repair authority | Default-off, per-run election with deterministic gates | Tenant/recipe default; repair as scan side effect | The #4495 owner decision permits only a specific, auditable authorization and preserves report-only behavior otherwise. |
| Security repair | Manual-only until separately approved | Include security findings in the general auto-queue | Security remediation has distinct risk and needs its own policy review. |

## What This Is Not

- Not acceptance of RDR-075, the maintenance LLD/EARS, or any runtime child.
- Not a rollout switch or permission to enable `maintenance_runs`.
- Not a calibrated numerical confidence system or a code-owned semantic
  classifier.
- Not authorization to auto-queue security repairs, broaden a repair, mutate
  source during a scan, or bypass M04 revalidation and authorization.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [General Maintenance Runs LLD](../maintenance-runs/maintenance-runs-design.md)
- [#4492 optimization umbrella](https://github.com/viamin/paid/issues/4492)
- [#4493](https://github.com/viamin/paid/issues/4493), [#4494](https://github.com/viamin/paid/issues/4494), [#4495](https://github.com/viamin/paid/issues/4495), and [#4496](https://github.com/viamin/paid/issues/4496)
- [#4636 design prerequisite](https://github.com/viamin/paid/issues/4636)
