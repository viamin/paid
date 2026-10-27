---
parent: maintenance-runs
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipe Family

> **Draft — pending design acceptance (#4636).** Companion to
> [`maintenance-runs-design.md`](../maintenance-runs/maintenance-runs-design.md)
> (itself still pending RDR-075 acceptance) and the draft
> [`RDR-075` design](../../rdrs/RDR-075-general-maintenance-runs.md). RDR-075
> states "Automatic repair is outside the initial scope and requires a
> separately approved policy" (§Recurring maintenance and repair); this LLD
> is the candidate draft of that policy, scoped narrowly to the optimization
> recipe family (#4492–#4496). It is a reviewable contract for the human
> review gate both accords require — it is **not** accepted intent, does not
> authorize automatic repair, and does not enable rollout. See
> [#4636](https://github.com/viamin/paid/issues/4636) for the acceptance
> request and [#4495](https://github.com/viamin/paid/issues/4495) for the
> owner decisions this LLD reconciles.

## Purpose

RDR-075 names optimization-shaped audits — dependency hygiene, stale feature
flags, documentation drift, test quality — as recipes beyond the first
unnecessary-code delivery. The optimization family (#4492) is the first of
those: a curated, extensible catalog of non-functional "contracting" audits
(performance, duplication, maintainability, security, cost, architecture,
test quality) that make a project more efficient without adding
functionality, plus an **optional, narrowly-scoped automatic-repair policy**
the base LLD explicitly withholds until separately approved.

This LLD owns three things the base `maintenance-runs` LLD does not:

1. The optimization type catalog and its curated menu (#4493).
2. The first three recipes and their honest-evidence contract (#4494).
3. The bounded, opt-in automatic-repair ("auto-queue") policy RDR-075
   requires before any scan may dispatch repair work without a per-finding
   selection (#4495), and the staged follow-on types that extend the catalog
   after the first recipes prove the contract (#4496).

It does not own maintenance's run lifecycle, report/finding schema, finding
identity, tool attachment, or manual repair handoff — those remain
`maintenance-runs`' territory, consumed here rather than duplicated. It does
not own semantic quality judgment mechanics — those are `agent_harness`
calls, structurally gated by this LLD's deterministic checks.

## Issue Mapping

| Issue | Role | Specs owned here |
| --- | --- | --- |
| [#4492](https://github.com/viamin/paid/issues/4492) | Tracking umbrella — coordination and final acceptance only, not an implementation prerequisite | None |
| [#4493](https://github.com/viamin/paid/issues/4493) | OPT-01: catalog and type menu | MAINT-OPT-001–007 |
| [#4494](https://github.com/viamin/paid/issues/4494) | OPT-02: first recipes and honest evidence | MAINT-OPT-010–016 |
| [#4495](https://github.com/viamin/paid/issues/4495) | OPT-03: semantic assessment and bounded auto-queue | MAINT-OPT-020–024, MAINT-OPT-030–039 |
| [#4496](https://github.com/viamin/paid/issues/4496) | OPT-04: staged follow-on types, security exclusion | MAINT-OPT-040–042 |

Each executable deliverable (#4493–#4496) depends independently on base
maintenance acceptance ([#4635](https://github.com/viamin/paid/issues/4635))
and the [#4604](https://github.com/viamin/paid/issues/4604) tool-handoff
evidence, per RDR-075's own dependency policy — this LLD's acceptance does
not substitute for either.

## Catalog and Type Menu

The optimization catalog extends `maintenance-runs`' recipe mechanism: a
code-defined, extensible list of entries, never a hard enum in the run
contract. Each entry carries a display name, a description of what the
recipe looks for, default metric hints (e.g. latency reduction, complexity
decrease, duplicated lines removed), and a pointer to its recipe definition
when one exists yet.

The initial curated menu has seven entries: Performance, Design/Architecture,
Code Duplication, Security Hardening, Cost/Resource Efficiency,
Maintainability/Readability, and Test Coverage & Quality. The first three
(#4494) ship with recipe definitions; the remaining four (#4496) are staged
follow-ons that register in the catalog ahead of their recipe content and
degrade to a custom-objective run until it lands.

The menu is presentation over the catalog, not a replacement for
`maintenance-runs`' free-form scope. A selection composes with scope exactly
as the base LLD already defines it, extended here: **scope for an
optimization run is paths, symbols, or a free-form natural-language target**
(a feature, a workflow, a page in the app) — not literal paths/symbols
alone. This reconciles the base LLD's narrower "(paths/symbols)" scope
description (`MAINT-011`) with RDR-075's own illustrative request ("Audit
parallel workflows A and B...") and OPT-01's stated scope contract; it
narrows nothing the base LLD already allows for a free-text question, it
only clarifies that *scope*, like guidance, accepts a natural-language
target.

## First Recipes and Honest Evidence

The first three recipes land on the base LLD's report/finding contract
unchanged:

- **Code Duplication** — tool-assisted (PMD CPD across languages;
  Exhale/Debride-class analyzers for Ruby where applicable). RDR-075's own
  caution governs: similarity alone never establishes that code should be
  shared; a proposed consolidation or deletion must consider deliberate
  independence and framework callbacks/dynamic invocation first (RDR-075
  §Validation scenario 3).
- **Maintainability/Readability** — tool-assisted where a complexity
  analyzer attaches, agent-assessed otherwise; cognitive-complexity
  regressions, overly complex functions, and naming/doc gaps are reportable
  findings with a proposed action.
- **Performance** — prompt-first initially: no blocking analyzer dependency.
  Agent investigation of hot paths, algorithmic improvements, and N+1/IO
  patterns within scope, with metric hints recorded on findings. Tool-
  assisted profiling can extend this recipe later without a contract change.

A recipe definition supplies objective, investigation instructions,
applicable evidence collectors, validation guidance, and default metric
hints, per the catalog's pointer contract above. Every finding from a
tool-assisted path records analyzer name/version/configuration provenance,
exactly as `maintenance-runs`' `MAINT-043` already requires; a prompt-first
finding records honestly that no tool attached rather than implying
analyzer evidence that doesn't exist. A scan with no qualifying findings
after every planned check completes is `clean` — a successful outcome, per
`MAINT-020`/`MAINT-044` — never a failure. Repeated scans update the
existing canonical finding's occurrence (`MAINT-026`/`MAINT-027`); the
optimization family introduces no second identity scheme.

## Semantic Assessment and Deterministic Gates

RDR-075 scopes a "confidence threshold" selection policy for auto-queue
(#4495, 2026-10-16 owner decision). Zero Framework Cognition requires that
semantic judgment live in an `agent_harness` call and that code hold only
structural checks and policy enforcement — a numerically calibrated
confidence score computed or interpreted by application code would invent
calibrated semantics RDR-075 never specified and ZFC forbids. This LLD
reconciles the two without discarding either:

- **Semantic assessment** is an `agent_harness` call, scoped per finding,
  against a versioned assessment rubric. It returns a **bounded,
  ordered standing** — not a numeric score — from a fixed small vocabulary
  (e.g. `insufficient` → `exploratory` → `supported` → `strong`), plus an
  explanation and evidence citations. The agent judges meaning; it never
  computes or self-reports a probability.
- **Selection policy** is a deterministic, project-configurable threshold
  expressed over that bounded standing (e.g. "`supported` or above"),
  compared in code. The LLM call supplies the standing; code performs the
  threshold comparison, never the reverse.
- **Fail-closed on uncertainty.** An unknown, malformed, or missing
  assessment excludes the finding from auto-queue selection — it is never
  defaulted to a qualifying standing. The finding still appears in the full
  report for manual selection.
- **Deterministic gates stay in code, independent of the assessment**:
  per-run opt-in authorization, category exclusion (Security Harding is
  `manual_only`; staged types are `default_deny`), per-repair budget caps,
  and canonical-finding idempotency. The semantic assessment decides
  *eligibility by standing*; these gates decide *whether dispatch is
  actually permitted* even for an eligible finding.

This division is this LLD's one substantive reconciliation beyond
restating #4495's decisions verbatim, and needs explicit owner confirmation
(recorded in Decisions & Alternatives below) — it is not a license to
invent a different numerical scheme at implementation time.

## Bounded Automatic Repair ("Auto-Queue") Policy

All six decisions recorded against #4495 (2026-10-16, agreed with product
owner) are preserved without substitution:

1. **Opt-in only, off by default.** Auto-queue is a per-run election
   captured at run start (trigger form + API/MCP, equivalent authorization)
   — never a tenant-wide or recipe-wide default. Omitting the election
   behaves exactly like a report-only run. A recurring `MaintenanceSchedule`
   cannot carry a standing election on the user's behalf: each occurrence is
   a fresh run, and the schedule's stored configuration does not include an
   auto-queue election. (A schedule inherits the base LLD's recurrence
   contract — timezone, overlap prevention, bounded catchup, disable — and
   nothing about auto-queue; see base LLD `MAINT-060`–`MAINT-064`.)
2. **Selection policy: standing threshold, not a numeric calibration.**
   Only findings whose semantic assessment meets the elected, configured
   standing threshold qualify (see previous section). The report is always
   delivered in full regardless of election; unselected or below-threshold
   findings remain available for manual selection exactly as today.
3. **Explicit per-repair budget caps.** Each auto-queued repair run carries
   its own cost/time limits, distinct from the originating maintenance
   run's budget. Exhaustion preserves collected evidence per the base LLD's
   `MAINT-024` evidence-preservation contract — it never discards partial
   repair work silently.
4. **Revalidation required, unchanged pathway.** An auto-queued repair goes
   through the same `MAINT-070`–`MAINT-072` repair-handoff pathway as a
   manually selected one, including `MAINT-071`'s revalidation against the
   repair checkout when the target revision has moved. Stale evidence never
   silently authorizes a repair — auto-queued or manual.
5. **Scope preservation.** An auto-queued repair's scope is bounded to its
   originating finding; broadening beyond that finding requires the same
   explicit human authorization RDR-075 already requires for any repair.
6. **Idempotency.** A canonical finding (`MAINT-026`) that already has an
   open or completed repair does not queue a second one on a later scan,
   auto-queued or manual.

Dispatch only follows a `completed` report outcome — a report that is
`partial`, `cancelled`, or `budget_exhausted` by definition means at least
one planned check did not finish, and RDR-075's "no scan directly deletes
source code or opens repair PRs as a side effect" guarantee extends to never
dispatching repair work from a report whose own coverage is incomplete. A
`clean` report has no findings to dispatch, trivially.

### Reconciling `MAINT-073` ("never... without an explicit user selection")

The base LLD's `MAINT-073` forbids creating repair work "as a direct side
effect of a maintenance scan without an explicit user selection." Auto-queue
dispatch happens without a second, per-finding click at report time — but it
is not a side effect *without* an explicit user selection: the run-start
opt-in election (decision 1, above) *is* that explicit selection, made once,
scoped to a specific threshold and budget, before the scan that later
qualifies findings against it. `MAINT-073` is clarified (not loosened) to
name this explicitly; see the base LLD's spec text for the reconciled
wording.

## Security Exclusion and Staged Follow-on Types

- **Security Hardening is `manual_only`, unconditionally**, regardless of
  assessed standing, until a dedicated accuracy/blast-radius policy review
  separately authorizes a security auto-queue path. This is a hard
  category exclusion in the deterministic gate layer, not a high threshold
  — no standing value makes a Security Hardening finding auto-queue
  eligible under this LLD.
- **A newly staged catalog type defaults to `default_deny`** for auto-queue
  eligibility at the time it is first registered (Cost/Resource Efficiency,
  Design/Architecture, Test Coverage & Quality — #4496). It does not inherit
  threshold-eligibility from the already-accepted OPT-03 policy; an operator
  decision is required to move a specific staged type from `default_deny` to
  threshold-eligible, evaluated per type once its recipe content and
  evaluation evidence exist (RDR-075 "staged after the first three recipes
  prove the contracts," #4496 §Summary).
- The Test Coverage & Quality catalog type reconciles with RDR-075's own
  stated future "test quality" recipe reference (§Problem Statement) rather
  than designing a second, overlapping recipe when that type is staged.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Confidence policy mechanics | Bounded ordered standing from an `agent_harness` structured call; deterministic threshold comparison in code | A numeric calibrated confidence score computed or interpreted in application code; raw tool-confidence feeding the gate directly | A numeric score invents calibrated semantics RDR-075 never specified and that ZFC assigns to AI judgment, not code; a bounded standing preserves #4495's "confidence threshold" language as a policy *name* without the calibration claim. Needs explicit owner confirmation — see Open Questions. |
| Auto-queue election scope | Per-run, at start, never inherited by a schedule | Schedule-level standing election; tenant-level default | #4495 decision 1 states "never a tenant-wide or recipe default"; a schedule is itself a recipe-shaped recurring default, so letting it carry a standing election would reintroduce exactly the default #4495 excluded. |
| Dispatch gating by report outcome | Only `completed` (and trivially `clean`) reports dispatch; `partial`/`cancelled`/`budget_exhausted` never do | Dispatch from any terminal outcome, revalidating later | RDR-075's "no scan directly deletes source code or opens repair PRs as a side effect" and the base LLD's incomplete-coverage guarantee both read as incompatible with queuing repair work from a report that admits it didn't finish looking. |
| Security repair eligibility | Hard `manual_only` category exclusion, independent of standing | A very high standing threshold for Security Hardening instead of exclusion | #4496 §Summary specifies exclusion "until a dedicated accuracy/safety review," not a higher bar within the existing policy; a threshold is still the existing policy, not a dedicated review. |
| New staged-type eligibility default | `default_deny`, decided per type at staging | Auto-inherit the accepted OPT-03 threshold policy | Silent inheritance would let a catalog addition (#4496, docs-only cataloging) implicitly authorize auto-repair for a type whose recipe and evaluation evidence don't exist yet; #4636's own charge is not to "silently authorize runtime behavior." |

## Open Questions & Future Decisions

### Resolved (owner decisions recorded against #4495, 2026-10-16)

1. ✅ Opt-in only, off by default, per-run election.
2. ✅ Selection policy is a confidence-shaped threshold (reconciled here to a
   bounded standing rather than a numeric score — see the decision above,
   still pending explicit owner confirmation of *that specific
   reconciliation*, not the underlying policy).
3. ✅ Explicit per-repair budget caps with evidence preservation on
   exhaustion.
4. ✅ Revalidation required through the unchanged M04/`MAINT-071` pathway.
5. ✅ Repair scope bounded to the approved finding.
6. ✅ Idempotency via canonical finding identity.

### Deferred

1. Exact catalog/recipe/assessment-rubric storage shapes (new columns vs.
   reuse of the base `MaintenanceReport`/`MaintenanceFinding` tables) —
   resolve during #4493/#4494/#4495 implementation, not before design
   acceptance, consistent with the base LLD's own deferral of its storage
   details.
2. The specific bounded-standing vocabulary and its versioned rubric content
   (what distinguishes `exploratory` from `supported`) — belongs to #4495
   implementation once `agent_harness`'s structured-response contract for
   this assessment is designed; this LLD fixes the vocabulary's *shape*
   (small, ordered, bounded) and its *role* (gates a deterministic
   threshold), not its final label set.
3. Which staged type (#4496) is the first candidate for owner review toward
   threshold-eligibility, and what that review requires — not decided here;
   each staged type remains `default_deny` until that review happens.
4. No project-owner catalog-authoring UI in v1 (per #4493); catalog entries
   remain code-defined.

## What This Is Not

- Not an acceptance of automatic repair as a general policy — this LLD is
  the narrow, optimization-family-scoped candidate RDR-075 requires, and it
  authorizes nothing until #4636 records explicit owner acceptance and the
  canonical artifacts merge.
- Not a numeric confidence-calibration scheme — the bounded standing
  described above is a policy classification, not a probability, and raw
  tool-confidence never substitutes for it.
- Not a rollout decision — the `maintenance_runs` guard, RDR-073's own tool
  guard, and base maintenance acceptance (#4635) remain independently
  authoritative and unchanged by this LLD's acceptance.
- Not an implementation of #4493–#4496 — those remain separately blocked on
  base maintenance acceptance (#4635) and the #4604 tool-handoff evidence,
  in addition to this LLD's acceptance.

## References

- [RDR-075: General Maintenance Runs](../../rdrs/RDR-075-general-maintenance-runs.md)
  — §Recurring maintenance and repair names the "separately approved policy"
  this LLD drafts.
- [`maintenance-runs` LLD](../maintenance-runs/maintenance-runs-design.md)
  — owns the run lifecycle, report/finding schema, and manual repair handoff
  this family consumes.
- [#4492](https://github.com/viamin/paid/issues/4492) (tracking umbrella),
  [#4493](https://github.com/viamin/paid/issues/4493) (catalog),
  [#4494](https://github.com/viamin/paid/issues/4494) (first recipes),
  [#4495](https://github.com/viamin/paid/issues/4495) (auto-queue policy,
  owner decisions 2026-10-16),
  [#4496](https://github.com/viamin/paid/issues/4496) (staged follow-on
  types)
- [#4636](https://github.com/viamin/paid/issues/4636) — this LLD's
  acceptance request
- [#4635](https://github.com/viamin/paid/issues/4635) — independent base
  maintenance acceptance dependency for #4493–#4496
