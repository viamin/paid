---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipes and Bounded Repair Policy

> **Draft — pending owner acceptance.** This is the design prerequisite for
> #4493–#4496, tracked by #4636. It extends the draft RDR-075 maintenance
> contract; it does not implement, enable, or accept maintenance or repair.

## Purpose and Boundaries

An optimization recipe is a curated, non-functional maintenance objective.
The catalog initially exposes Performance, Design / Architecture, Code
Duplication, Security Hardening, Cost / Resource Efficiency, Maintainability /
Readability, and Test Coverage & Quality. A catalog entry supplies a display
name, description, metric hints, recipe reference, and repair standing. It is
code-defined but extensible by adding an entry, not a run-contract enum or a
migration. An unrecognized type becomes a custom-objective maintenance run.

The menu is equivalent UI/API/MCP presentation over the catalog. Type selection
is optional, is snapshot with the base run objective/scope/guidance and recipe
version, and survives retries. Scope may name files, symbols, a feature, or a
page; it bounds recommendations, never the supporting callers, tests,
framework entry points, or intent evidence needed to assess a claim. Reports
must disclose that supporting inspection and every coverage limitation.

#4492 is tracking-only. #4493 owns catalog/menu/snapshot delivery; #4494 owns
the first recipes; #4495 owns the narrowly pre-authorized auto-queue path; and
#4496 owns staged types. Each implementation remains independently blocked on
base maintenance acceptance (#4635) and the live tool-handoff evidence (#4604).

## Recipes and Honest Evidence

The first recipes are Code Duplication, Maintainability / Readability, and
Performance. Duplication and maintainability may consume RDR-073 tools through
the base maintenance adapter contract; similarity or a tool result alone never
establishes that code should be shared. Performance is prompt-first until a
credible profiler is available. Every report records whether its evidence was
tool-assisted or prompt-only, tool/version/configuration provenance where used,
counterevidence, and incomplete coverage. A clean prompt-only report is valid
only when no tool check was planned; a failed planned check remains partial
under MAINT-020–024.

Security, cost, design/architecture, and test-quality recipes are staged after
the first recipes. Their catalog availability does not imply an automatic repair
standing. Test-quality work reconciles with, rather than duplicates, RDR-075's
planned test-quality recipe.

## Assessment and Policy Gates

`agent_harness` performs the semantic assessment of a finding using a versioned
structured rubric: recommendation, bounded rationale, cited evidence and
counterevidence, proposed validation, and a policy standing. The assessment is
meaningful judgment, not framework inference. Raw analyzer confidence is
evidence only and never authorizes repair.

The standing is an ordered, bounded policy field — `supported`, `marginal`, or
`unsupported`; missing, malformed, stale, or unknown assessment fails closed.
It is not a calibrated probability. The configured threshold from #4495 is a
minimum standing, evaluated per run on findings only; its default is
`supported`. Code may validate the response shape and deterministically enforce
the configured standing, but may not infer standing from text or invent a
numeric confidence score.

Automatic repair remains off unless an authorized user explicitly elects it at
run start. The election is a snapshot and can narrow permitted categories or
budgets, never elevate a catalog standing or create a tenant-wide, schedule, or
recipe default. It queues nothing unless the report is `completed`, the finding
passes the standing threshold, the category permits it, and every gate below
passes. The complete report is delivered regardless of selection.

Before dispatch, deterministic code must verify the base maintenance guard and
repair-path authorization, a current approved finding, a non-stale assessment,
explicit per-repair cost/time caps, the finding-only repair scope, revalidation
against a moved repair checkout, and idempotency keyed by canonical finding
identity. Failed gates visibly retain the report/finding and explain the
non-dispatch; they never silently queue or discard repair work. Exhaustion
preserves repair evidence per the base contract. Repeated occurrences of the
same canonical finding do not create duplicate repair work.

Security Hardening is `manual_only`. Cost, Design / Architecture, and Test
Coverage & Quality are `default_deny` until separate owner authorization backed
by evaluation evidence changes their standing. A run-start election cannot
override either posture. Automatic repair never bypasses the existing M04
revalidation, authorization, source-report link, PR review, or rollout guard.

## Decisions and Non-goals

| Decision | Chosen policy | Why |
| --- | --- | --- |
| Confidence semantics | Agent-produced discrete standing, not a numeric probability | ZFC keeps semantic judgment in `agent_harness`; a numeric calibration is unsupported false precision. |
| Default threshold | `supported` | Automatic mutation needs the strictest currently defined policy standing. |
| Auto-queue timing | Completed reports only | Partial, cancelled, and budget-exhausted coverage cannot silently authorize a repair. |
| Idempotency | Canonical finding identity | Report occurrences change; the recurring problem identity must not duplicate repair work. |
| Security | Manual-only | Requires a dedicated accuracy and safety review before any automatic-repair authority. |

This design does not add a feature flag, schema, runtime behavior, schedule
election, admin authoring UI, numerical confidence calibration, automatic
security repair, or rollout authority. It rides the existing default-off
`maintenance_runs` guard if later accepted and implemented.

## Acceptance Required

Human owner acceptance is required for this complete package: discrete standing
threshold semantics, `supported` default, completed-only dispatch, election
that can only narrow, category standing, canonical-identity idempotency, and
the base MAINT-011/073 reconciliation. A preparation PR must use `Tracks #4636`
and carry the review hold until accepted. #4636 remains open with that concrete
Inbox decision; merge of this draft neither accepts RDR-075 nor releases
#4493–#4496.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [General Maintenance Runs](../maintenance-runs/maintenance-runs-design.md)
- #4492–#4496, #4604, #4635, and #4636
