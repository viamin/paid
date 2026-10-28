---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Maintenance Optimization Recipes

> **Draft — pending owner acceptance.** This is the reviewable optimization
> extension to the draft [general maintenance runs LLD](../maintenance-runs/maintenance-runs-design.md)
> and [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md). It reconciles
> the owner decisions recorded in [#4495](https://github.com/viamin/paid/issues/4495)
> without authorizing runtime behavior. Base maintenance acceptance, the
> `maintenance_runs` default-off rollout guard, and required tool-handoff
> evidence remain independent prerequisites for implementation.

## Purpose

Optimization recipes are a curated family of report-only maintenance
investigations. They help a project improve non-functional qualities without
changing product behavior: performance, design and architecture, code
duplication, security hardening, cost and resource efficiency, maintainability
and readability, and test coverage and quality.

The family extends the existing maintenance run and report contracts. It does
not create a second run lifecycle, evidence store, tool catalog, authorization
system, or repair pathway. A selection can have an unconstrained natural
language scope; as with all maintenance runs, that scope bounds recommendations
rather than inspection needed to substantiate them, and reports disclose any
supporting inspection outside it.

## Catalog and Recipe Selection

`MaintenanceOptimization::Catalog` is code-defined and is the single source
for catalog entries and the UI/API/MCP type menu. Each entry has a stable key,
display name, description, default metric hints, and an optional recipe
definition pointer. Adding an entry is catalog data, not an `AgentRun` enum or
database migration. The seven initial entries are:

| Key | Type | Initial delivery |
| --- | --- | --- |
| `performance` | Performance | Prompt-first |
| `architecture` | Design / Architecture | Staged follow-on |
| `duplication` | Code Duplication | Tool-assisted where available |
| `security_hardening` | Security Hardening | Staged follow-on, manual repair only |
| `cost_efficiency` | Cost / Resource Efficiency | Staged follow-on, prompt-first |
| `maintainability` | Maintainability / Readability | Tool-assisted where available |
| `test_quality` | Test Coverage & Quality | Staged follow-on |

The menu is presentation over this catalog. UI, authenticated API, and MCP
admit selections through the same `maintenance_runs` guard and project-scoped
authorization as other maintenance starts. No selection is required: an absent
selection remains a general report-only maintenance request. An unknown or
unmapped catalog value becomes a custom-objective request; it never causes a
start error or grants a recipe's policy.

The selected entry, resolved recipe version, scope, guidance, collector
configuration, and metric hints are immutable run-start provenance and survive
retries. A later catalog edit cannot reinterpret a completed report.

## Evidence and Semantic Assessment

A recipe names investigation instructions, compatible evidence collectors,
validation guidance, and metric hints. Collectors use the existing RDR-073 and
maintenance-tool contracts. A missing applicable collector permits a
prompt-first recipe; it must be represented as prompt-only evidence and cannot
be represented as a completed tool check. The report outcome and coverage
semantics remain those of `MAINT-020` through `MAINT-024`.

Tools supply structural observations and raw provenance, not a conclusion that
a repair is appropriate. Semantic assessment — whether evidence supports a
finding, relevant counterevidence, recommendation scope, and repair
eligibility — is an `agent_harness` call with a structured response. Paid does
not call providers directly, parse prose for semantic intent, or calculate
repair eligibility from tool scores or keywords.

The policy's "confidence threshold" is a configured ordered assessment band
over that structured response. It is a deterministic comparison after the
agent's semantic assessment, not a claimed calibrated probability, a numeric
score inferred by framework code, or a conversion from raw analyzer
confidence. The versioned policy snapshot names the allowed bands and selected
minimum so a future implementation can audit the decision without inventing
numerical confidence semantics.

The initial recipes are duplication, maintainability, and performance. A
duplication recommendation must consider intentional independence, framework
callbacks, and dynamic invocation; similarity alone is not enough.
Maintainability may combine available complexity evidence with agent
assessment. Performance is prompt-first until credible profiling evidence is
integrated. Follow-on security, cost, architecture, and test-quality recipes
use the same evidence contract; test quality must reconcile with, rather than
duplicate, RDR-075's planned test-quality objective.

## Bounded Automatic Repair Policy

The default is report-only. An authorized user may explicitly elect an
optimization-only auto-queue policy at run start. The election is absent by
default, is never a tenant-wide or recipe-wide default, and snapshots:

- the minimum ordered assessment band;
- explicit cost and time caps for each repair run; and
- the selected optimization recipe and source report lineage.

When a report completes, code may queue a repair only after all deterministic
gates succeed, in this order:

1. `maintenance_runs` is enabled and the original run holds a valid,
   authorized per-run election snapshot.
2. The finding belongs to the elected optimization recipe, is open, has a
   structurally valid semantic-assessment response at or above the snapshot's
   configured band, and is not `security_hardening`.
3. The proposed repair scope is no broader than the finding's recorded
   affected symbols and claim. A wider scope requires a new explicit human
   authorization.
4. The M04 repair pathway authorizes the repair creation, assigns the exact
   per-repair cost/time caps, and links the repair to its report and canonical
   finding identity.
5. The finding identity has no existing active or completed auto-queued repair
   under that election. A transactional idempotency key derived from the run,
   finding identity, and policy snapshot prevents duplicate queueing across
   repeated report processing.

The repair pathway revalidates the finding against its repair checkout before
applying a recommendation whenever the target revision has moved. A failed or
inconclusive revalidation is visible and stops repair application; it cannot
silently broaden scope, apply stale evidence, or queue a replacement without
another authorized evaluation. Cost or time exhaustion preserves collected
evidence using the base maintenance outcome contract.

Security hardening findings are always report-only and manually selected until
a dedicated accepted policy establishes their accuracy and blast-radius
criteria. Disabling maintenance admission stops future auto-queues, preserves
reports, and does not cancel repairs already active through the normal repair
lifecycle.

## Delivery Mapping

| Scoped contract | Deliverable | Issue |
| --- | --- | --- |
| Catalog entries, menu parity, custom-objective fallback, immutable selection provenance | OPT-01 | [#4493](https://github.com/viamin/paid/issues/4493) |
| Duplication, maintainability, and performance recipes; honest evidence and evaluation | OPT-02 | [#4494](https://github.com/viamin/paid/issues/4494) |
| Per-run election, ordered assessment-band threshold, authorization/budget/scope/idempotency/revalidation gates | OPT-03 | [#4495](https://github.com/viamin/paid/issues/4495) |
| Security manual-only rule and staged cost, architecture, and test-quality recipes | OPT-04 | [#4496](https://github.com/viamin/paid/issues/4496) |

[#4492](https://github.com/viamin/paid/issues/4492) is tracking and final
acceptance coordination only. It owns no executable prerequisite claim and
does not authorize implementation, automatic repair, or rollout.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Recipe type representation | Code-defined extensible catalog | `AgentRun` enum; project-admin authoring UI | Catalog entries evolve independently of the run lifecycle, while v1 needs a reviewed curated menu rather than tenant-defined execution behavior. |
| Semantic eligibility | Structured `agent_harness` assessment plus deterministic policy gates | Tool-score-only selection; framework keyword/heuristic classification | Meaning and counterevidence require semantic judgment; authorization, budgets, scope, idempotency, and revision checks must remain deterministic control-plane work. |
| Confidence threshold | Versioned ordered assessment band, without calibration claim | Numeric probability threshold; raw analyzer confidence | Preserves the owner's threshold policy while avoiding unsupported numerical semantics or framework inference from tool output. |
| Automatic repair authority | Explicit per-run, off-by-default pre-authorization | Tenant default; automatic repair for every qualifying finding | The election is narrow, auditable, revocable by guard disablement for future admissions, and preserves RDR-075's default report-only posture. |
| Security repairs | Manual selection only | Include security in OPT-03 auto-queue | Security changes require their own accepted accuracy and blast-radius policy. |

## Open Questions & Future Decisions

### Resolved

1. The #4495 owner decisions define the proposed OPT-03 boundaries: per-run
   opt-in, threshold filtering, explicit budgets, revalidation, bounded scope,
   and finding-identity idempotency.
2. The confidence threshold does not assert calibrated numerical confidence;
   semantic assessment is delegated through `agent_harness`.

### Deferred

1. The concrete assessment-band vocabulary and structured response schema must
   be approved with the implementation contract; this draft only requires an
   ordered, versioned policy representation.
2. Security auto-repair needs a dedicated accepted policy and is excluded from
   OPT-03 until then.
3. Recipe-specific collectors, evaluation corpus, and metric instrumentation
   are delivered by OPT-02/OPT-04 after base maintenance and tool-handoff
   prerequisites are met.

## What This Is Not

- Not acceptance of RDR-075, its base maintenance LLD, or this extension.
- Not implementation, rollout, or an enablement path for `maintenance_runs`.
- Not a policy allowing a scan to mutate source code or a repair to bypass the
  existing M04 repair pathway.
- Not an authorization to auto-queue a security repair.

## References

- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md)
- [General Maintenance Runs LLD](../maintenance-runs/maintenance-runs-design.md)
- [#4492 optimization tracking umbrella](https://github.com/viamin/paid/issues/4492)
- [#4493 OPT-01](https://github.com/viamin/paid/issues/4493), [#4494 OPT-02](https://github.com/viamin/paid/issues/4494), [#4495 OPT-03](https://github.com/viamin/paid/issues/4495), and [#4496 OPT-04](https://github.com/viamin/paid/issues/4496)
