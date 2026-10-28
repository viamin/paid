---
parent: PAID
prefix: OPT-MAINT
---

# Low-Level Design: Optimization Maintenance Recipes and Bounded Repair Policy

> **Draft — pending owner acceptance.** This is a docs-only prerequisite for
> [#4493](https://github.com/viamin/paid/issues/4493)–[#4496](https://github.com/viamin/paid/issues/4496).
> It refines the future optimization recipe family on top of draft RDR-075;
> it does not enable maintenance runs, automatic repair, or rollout.

## Purpose

The optimization recipe family lets a project owner request a non-functional
maintenance investigation from a curated catalog while retaining RDR-075's
report-first, evidence-backed lifecycle. A catalog selection is an aid to
recipe selection, not an enum added to the maintenance-run contract and not
repair authority.

The proposed bounded auto-queue policy is a narrow exception to the base
manual repair handoff. It is available only when a user elects it for one run
at run start. It remains default-off, uses the ordinary authorized repair
path, and cannot authorize security repairs. This LLD records the policy for
review; acceptance and later implementation remain independent of base
maintenance acceptance and each child issue's prerequisites.

## Catalog, Recipes, and Scope

The code-defined catalog has seven initial entries: Performance, Design /
Architecture, Code Duplication, Security Hardening, Cost / Resource
Efficiency, Maintainability / Readability, and Test Coverage & Quality. An
entry contains its display name, investigation description, metric hints, and
the underlying recipe reference when that recipe exists. Adding an entry is a
catalog/recipe change, not an enum migration or a project-admin authoring UI.

The UI, authenticated API, and MCP start contracts present the same catalog
and preserve RDR-075's common start authorization. A user may start without a
catalog selection; an unknown or unmapped selection becomes the existing
custom-objective maintenance request rather than an error. The selected entry,
or that custom-objective result, is part of the immutable run snapshot and
survives retry.

Free-form scope composes with any catalog entry and imposes no artificial
scope type limit: files, a feature, and an application page are valid inputs.
As in MAINT-012 through MAINT-014, named scope must resolve before coverage is
claimed, while recommendations are bounded by the requested scope. Supporting
inspection may include callers, tests, and framework entry points outside that
scope; a recommendation that expands the repair scope still needs explicit
human authorization.

The initial executable recipes are Code Duplication, Maintainability /
Readability, and Performance. They define objective, investigation
instructions, applicable collectors, validation guidance, and metric hints.
Tool output is evidence only: duplication recommendations must account for
intentional independence and dynamic/framework invocation. Performance may be
prompt-first when no applicable collector attaches; its report must say so.
Security, cost/resource, architecture, and test-quality recipes are staged
follow-ons. Security remains report-only with manual repair selection. The
test-quality recipe must reuse rather than duplicate RDR-075's planned
test-quality objective.

## Evidence and Semantic Assessment

Collectors and RDR-073 attachments provide structural evidence and
provenance. Semantic assessment — whether evidence supports a finding,
counterevidence, proposed action, validation plan, and policy-eligible
confidence result — is performed through `agent_harness` with a structured
response. Paid treats all repository and collector content as untrusted data;
it does not infer semantic suitability with keywords, tool scores, or local
heuristics.

A raw collector score is neither a repair authorization nor a calibrated
probability. The auto-queue election captures a configured confidence
threshold policy, and the assessment returns the corresponding structured
policy result plus cited evidence and counterevidence. The configuration owns
the threshold representation and ordering; this LLD makes no claim that the
result is numerically calibrated, statistically predictive, or comparable
across recipes. Paid only performs deterministic comparison and gate checks
against the persisted policy and structured result.

Reports retain the underlying evidence, collectors that completed or did not
complete, coverage limits, and the assessment disposition. A partial report
must remain visibly partial; a qualifying finding cannot make incomplete
coverage look complete. Reports always show findings that do not pass the
elected auto-queue policy for manual selection.

## Bounded Auto-Queue Authorization

Auto-queue is evaluated after a report records findings, never during
collection. It may queue a repair only when all deterministic gates pass:

1. `maintenance_runs` is enabled for the tenant and the run captured an
   explicit auto-queue election; omission is report-only behavior.
2. The finding comes from an optimization recipe, is not Security Hardening,
   is open, has the persisted structured policy result meeting the captured
   threshold, and has report evidence and coverage state available for repair
   inspection.
3. The intended repair has the captured per-repair cost and time limits, the
   source report/finding provenance, and a scope no broader than the finding.
4. The ordinary repair-creation authorization succeeds, and the M04 repair
   handoff revalidates the finding against the repair checkout if its revision
   differs from the report revision.
5. No repair already exists or is active for the same canonical finding
   identity and repair target under this election.

The policy gate neither interprets evidence nor silently broadens scope. A
failed authorization, failed revalidation, exhausted budget, duplicate, or
ineligible finding produces an inspectable non-queued disposition; it does
not fall back to another finding or silently discard the report. A disabled
maintenance guard blocks new auto-queue admissions but does not cancel active
repair runs or delete reports. The policy creates repair runs only through the
existing M04 handoff and preserves its report/finding links and evidence-on-
budget-exhaustion behavior.

## Delivery Mapping

| Issue | Executable prerequisite owned after this intent is accepted |
| --- | --- |
| [#4492](https://github.com/viamin/paid/issues/4492) | Tracking umbrella only; it owns no runtime deliverable and is not a prerequisite to close before children run. |
| [#4493](https://github.com/viamin/paid/issues/4493) | Catalog resolution, curated menu parity, custom-objective fallback, and immutable selection snapshot. |
| [#4494](https://github.com/viamin/paid/issues/4494) | The first three recipes, their evidence provenance, honest prompt-first performance coverage, and repeated-finding behavior. |
| [#4495](https://github.com/viamin/paid/issues/4495) | Per-run election, structured confidence-policy gate, deterministic authorization/budget/idempotency/revalidation gates, and provenance-backed bounded repair creation. |
| [#4496](https://github.com/viamin/paid/issues/4496) | Staged follow-on recipes, including security's manual-only repair boundary and test-quality reconciliation. |

All implementation issues remain separately blocked by base RDR-075
acceptance, the maintenance milestones they name, and applicable tool-handoff
evidence. This mapping does not release those dependencies.

## Decisions and Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Type representation | Code-defined extensible catalog over recipes | Hard enum or project-admin authoring in v1 | A catalog can add types without migrations while preserving custom objectives and a curated UI. |
| Semantic confidence | `agent_harness` structured policy result, mechanically gated by Paid | Raw tool score, keyword heuristics, or an asserted calibrated numeric probability | Semantic quality belongs to the agent; policy enforcement belongs to code. This avoids claiming calibration the evidence does not establish. |
| Automatic repair authority | Per-run, explicit, default-off election with bounded repair gates | Tenant-wide default or automatic repair from a catalog selection | The owner-approved policy permits a narrow pre-authorization, not ambient repair authority. |
| Security repair | Manual selection only | Include security findings in auto-queue | Security hardening needs a dedicated accuracy and blast-radius authorization before automation. |

## Boundaries and Acceptance

- This segment consumes MAINT-001–MAINT-073 and does not change tool
  provisioning, matching, tenant authorization, or the M04 repair pathway.
- It does not authorize automatic repair until an owner accepts these precise
  revisions and the canonical HLD/LLD/EARS artifacts merge.
- It does not create a rollout decision. `maintenance_runs` remains default
  off, and every future implementation must preserve that guard.
- The preparation PR tracks [#4636](https://github.com/viamin/paid/issues/4636)
  until an owner records acceptance. If that review is outstanding, #4636
  stays open with the acceptance decision in the Inbox.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [General Maintenance Runs LLD](../maintenance-runs/maintenance-runs-design.md)
- [#4492 optimization tracking umbrella](https://github.com/viamin/paid/issues/4492)
- [#4495 owner-approved bounded auto-queue policy](https://github.com/viamin/paid/issues/4495)
