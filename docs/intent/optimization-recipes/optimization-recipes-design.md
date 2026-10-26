---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Maintenance Optimization Recipes

> **Draft — pending owner acceptance and merge.** This is a docs-only
> prerequisite for [#4493](https://github.com/viamin/paid/issues/4493)–[#4496](https://github.com/viamin/paid/issues/4496), not an implementation
> authorization. It extends the draft [RDR-075 maintenance contract](../../rdrs/RDR-075-general-maintenance-runs.md) without accepting RDR-075 or enabling its `maintenance_runs` guard.

## Purpose

The optimization family needs a reviewable contract for selecting maintenance
recipes, reporting evidence honestly, and, only where explicitly elected,
creating bounded follow-up repair work. It gives product owners a stable
catalog rather than treating recipe titles, issue text, or analyzer output as
policy. [#4492](https://github.com/viamin/paid/issues/4492) is tracking-only;
the executable prerequisites are [#4493](https://github.com/viamin/paid/issues/4493) (catalog), [#4494](https://github.com/viamin/paid/issues/4494) (initial recipes),
[#4495](https://github.com/viamin/paid/issues/4495) (bounded auto-queue policy), and [#4496](https://github.com/viamin/paid/issues/4496) (staged types).

## Catalog and Recipe Contract

The application owns a versioned, code-defined catalog. Each entry has a
stable key, display name, type, recipe version, supported repository signals,
recommended scope form, evidence collectors, limitations, and repair posture.
An unknown, disabled, or structurally invalid key is not admitted. A catalog
entry selects instructions and bounded evidence collection; it never grants
repair authority.

The initial catalog types are Unnecessary Code, Duplication, Complexity, and
Obsolete Behavior. They produce recommendations within the user-requested
scope, while agents may inspect callers, tests, framework entry points, and
design artifacts outside that scope as supporting evidence. Such inspection
must be cited and does not broaden a repair. Natural-language targets are
accepted alongside paths and symbols; ambiguity receives clarification rather
than a broadened scan.

Evidence is honest by construction: tool output is candidate evidence, not a
finding or deletion authority. Every recommendation records positive evidence,
known counterevidence, coverage limits, provenance, and a validation plan.
An unavailable collector, incomplete coverage, cancellation, or exhausted
budget remains visible through the RDR-075 report outcome; it cannot be
presented as a clean or completed basis for auto-queue.

## Semantic Assessment and Policy Gates

`agent_harness` performs semantic assessment with a versioned structured
response: an ordered repair-eligibility standing (`supported`, `marginal`,
`unsupported`, or `unknown`), rationale, citations, counterevidence, and
proposed bounded action. This is a meaning judgment, so application code must
not derive it from title keywords, text heuristics, or raw analyzer scores.
The standing is an ordered policy label, not a calibrated probability; raw
tool confidence is retained as evidence and never becomes an authorization
input. Malformed, missing, or stale assessments are `unknown` and fail closed.

Code validates the response shape and applies only deterministic gates:
project and creation-path authorization, the `maintenance_runs` guard,
catalog repair posture, recorded election, completed-report status, minimum
standing, explicit per-repair cost/time caps, revision revalidation, scope,
and idempotency. This division preserves Zero Framework Cognition: semantic
judgment belongs to `agent_harness`; policy and state transitions belong to
the control plane.

## Bounded Automatic Repair

The report-only default remains unchanged. A user may opt in at manual run
start through equivalent UI, API, and MCP surfaces, recording a minimum
standing and explicit default caps for each repair run. Omission means no
auto-queue. Schedules cannot elect because a standing schedule election would
be a recipe or tenant default rather than the owner-approved per-run choice.
The complete report is delivered whether or not any finding qualifies.

Only a `completed` report can dispatch a qualifying repair. The repair is
created through the existing M04 issue/PR-creation pathway, carries source
report/finding provenance and the caps, and remains bounded to the finding's
approved action. A moved target revision requires revalidation before the
repair applies; failed or unavailable revalidation is visible and dispatches
no unreviewed change. The canonical finding identity is the idempotency key,
so later occurrences cannot create duplicate repair work.

Catalog repair posture is default-deny and may be narrowed, never widened, by
a run-start election. Security Hardening is `manual_only` pending a separately
approved accuracy and safety review. Cost Optimization, Design and
Architecture, and Test Coverage are `default_deny` staged types until separate
owner authorization with evaluation evidence changes their posture.

## Decisions & Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Catalog authority | Code-defined versioned catalog | Free-form labels; analyzer-owned catalog | Stable keys make selection and provenance auditable without deriving policy from untrusted text. |
| Eligibility semantics | `agent_harness` ordered standing | Calibrated numeric confidence; analyzer confidence | No supported calibration exists; a numeric threshold would imply false precision, while semantic meaning belongs in the agent call. |
| Auto-queue control | Per-run opt-in election, default off | Tenant default; recipe default; schedules | Preserves #4495's explicit pre-authorization without turning recurring configuration into ambient repair authority. |
| Security repair posture | Manual-only | Include it in auto-queue | Security repairs have distinct safety and accuracy requirements and need separate approval. |
| Repeat handling | Canonical finding identity idempotency | Occurrence or report key | Recurring occurrences are evidence, not new authority to duplicate repair work. |

## Dependencies and Boundaries

This segment is a draft preparation artifact. #4493–#4496 remain independently
blocked on owner acceptance and merge of this segment, accepted base
maintenance intent (#4635), RDR-075 acceptance, M01–M04 implementation
sequencing, and #4604's live tool-handoff evidence where applicable. It does
not require closing #4492 or any runtime child. It adds no feature flag and
does not change the existing default-off `maintenance_runs` rollout guard.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [Maintenance runs LLD](../maintenance-runs/maintenance-runs-design.md)
- [#4495 owner decisions](https://github.com/viamin/paid/issues/4495)
- [#4636 design prerequisite](https://github.com/viamin/paid/issues/4636)
