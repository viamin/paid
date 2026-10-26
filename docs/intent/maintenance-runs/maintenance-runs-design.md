---
parent: PAID
prefix: MAINT
---

# Low-Level Design: General Maintenance Runs

> **Draft — pending design acceptance.** Companion to
> [`docs/high-level-design.md`](../../high-level-design.md) and the draft
> [`RDR-075` design](../../rdrs/RDR-075-general-maintenance-runs.md)
> (`docs/rdrs/RDR-075-general-maintenance-runs.md`, merged to main via
> #4308). RDR-075 is still **Status: Draft**, not yet accepted. This LLD and
> its EARS specs are
> reviewable contracts produced for the human review gate that RDR
> acceptance requires; they are not accepted intent and authorize no
> implementation. See
> [`audit-report-2026-10-23-rdr-075-m00-tool-handoff-validation.md`](../../rdrs/audit-report-2026-10-23-rdr-075-m00-tool-handoff-validation.md)
> for the tool-handoff evidence this design relies on.

## Purpose

Paid needs a maintenance investigation that a project owner can start without
first writing an issue or attaching a PR, with a durable, evidence-backed
report as its outcome. A maintenance run has an explicit objective, optional
scope, optional free-text guidance, and a report-only outcome — it never
mutates source code itself. The first delivery's objective is unnecessary-code
investigation (unused code, dependencies, duplication, complexity, obsolete
behavior); the shape generalizes to future objectives (dependency hygiene,
stale feature flags, documentation drift, test quality) without a new run
type per objective.

This LLD owns maintenance objectives, scope, reports, finding identity,
recurring schedules, and the handoff to bounded repair work. It does not own
tool attachment, matching, provisioning, or sidecar hardening — that remains
[RDR-073](../../rdrs/RDR-073-marketplace-tool-sidecars.md) /
[`marketplace-tool-sidecars`](../marketplace-tool-sidecars/marketplace-tool-sidecars-design.md),
consumed rather than duplicated.

## Storage Contract

A maintenance run is a new `AgentRun` goal (`"maintenance"`), not a new
model. Each run persists, immutably once started:

- `project_id`, the pinned repository revision (branch/SHA) the run
  investigated, and `issue_id` (nullable — issue-less manual runs are
  first-class).
- `objective` (the recipe key, or `nil` for a free-text user question),
  `scope` (optional paths, symbols, or free-form natural-language text the
  user named — files, a feature, or a page in the app are all valid scope),
  and `guidance` (free-text instructions), captured verbatim at run start.
- `recipe_version` and the resolved tool versions/configuration actually
  used, for provenance (RDR-073 attachment metadata plus any native-CLI
  analyzer version string captured at invocation time).
- `cost_limit`/`time_limit` snapshots, consistent with existing run budget
  fields.

A maintenance run produces exactly one `MaintenanceReport`, associated
1:1 with the run (reports are not retried in place — a retry or a new
investigation against another revision is a new run and a new report). The
report records:

- Its outcome: `clean`, `completed`, `partial`, `cancelled`, or
  `budget_exhausted`. There is no `failed` outcome distinct from `partial` —
  every terminal state reports what was actually covered; a report can never
  claim `clean` or `completed` while a check did not complete.
- Which checks/analyzers actually ran to completion, and which did not
  (missing tool, parse failure, truncated analysis, unavailable service),
  so partial coverage is visible rather than silently folded into a clean
  result.
- The resolved scope actually investigated and any exclusions, distinct from
  the scope the user requested (an ambiguous or missing named target is a
  clarification outcome, not a silent repository-wide scan).

Each `MaintenanceFinding` is a canonical, **project- and recipe-scoped**
record, identified from its claim and affected symbols (not line numbers
alone). It does not belong to one report: it owns the durable current finding
identity and lifecycle, so a repeated scan updates that same canonical finding
rather than creating duplicate repair work. A canonical finding records:

- Its identity inputs: `category`, current `locations`/`symbols`, and `claim`.
- `status`: `open`, `dismissed` (with a required reason), or
  `repaired` (linked to the repair work that addressed it).
- A revalidation marker set when supporting evidence materially changes
  across scans, forcing a dismissed finding back for reassessment rather
  than staying silently dismissed forever.

Each report owns an immutable `MaintenanceFindingOccurrence` for every
canonical finding observed in that run. The occurrence links the report and
canonical finding and snapshots that run's locations/symbols, claim,
supporting evidence, counterevidence, analyzer provenance, verification
disposition, and observed status. A later scan creates a new occurrence for
the same canonical finding; it must never reattach or overwrite an earlier
report's occurrence. Thus report inspection retains the evidence actually
observed at that pinned revision while the canonical finding retains its
cross-run status. The no-duplicates rule applies to canonical findings, not
to the necessary per-report occurrence records.

A `MaintenanceSchedule` (project-scoped, opt-in) captures the same
objective/scope/guidance/limits shape and objective admission rule as a manual
run plus recurrence:
timezone, next-occurrence computation, non-overlap with an equivalent
in-flight run, and bounded missed-occurrence catchup. Disabling a schedule
stops future dispatch without deleting prior reports or cancelling an
active run — cancellation is a separate explicit action on the run itself.
Recurring layered-verification audits ([RDR-076](../../rdrs/RDR-076.md)
optional trigger, [#4440](https://github.com/viamin/paid/issues/4440)) are an
intended consumer of this scheduling contract: recurrence, overlap
prevention, catchup, and disable semantics are owned here, while audit
admission, scope/revision identity, budgets, and evidence/Inbox lifecycle are
owned by the [layered-verification](../layered-verification/layered-verification-design.md)
segment (`LAYERED-VERIFY-030`–`-032`); the concrete schedule representation
for that objective is decided at design acceptance.

## API, UI, and MCP Contract

Manual maintenance runs are reachable equivalently from the UI, the
authenticated API, and the agent-accessible MCP surface — none of the three
is a thicker or thinner contract than the others. For every action below,
each surface enforces the same project-scoped authorization decision; repair
selection also applies the existing authorization of the selected issue or
PR-creation pathway:

- **Start**: an authorized user supplies a project, optional objective (recipe
  key), optional scope (paths/symbols), and optional free-text guidance. A
  start request must include either a recipe objective or nonblank guidance;
  scope alone is not an investigation objective. Response identifies the
  created run and its resolved (or pending-clarification) scope.
- **Inspect**: an authorized user reads run status, report outcome once
  terminal, and findings with their status.
- **Cancel**: an authorized user takes an explicit action distinct from
  schedule disable; it preserves whatever evidence was already collected.
- **Select repair**: an authorized user chooses one or more findings to
  become a bounded issue or PR-creation run through existing authorized
  pathways — this create path is a new run/issue through existing creation
  goals, not a new side-effecting action hung off the maintenance report.
  The selection may also be pre-authorized as an explicit run-start
  election under a separately approved selection policy; the only such
  policy drafted is the optimization family's
  ([`maintenance-optimization`](../maintenance-optimization/maintenance-optimization-design.md)),
  and absent an election the run stays report-only (`MAINT-073`).

All three surfaces are gated by the `maintenance_runs` guard (below); none
of the three may admit a maintenance run while the guard is off for the
project's tenant.

## Run-Outcome Contract

A maintenance run's terminal report outcome is one of exactly five values,
and the implementation must not collapse them:

| Outcome | Meaning |
| --- | --- |
| `clean` | Every check that was supposed to run completed; no findings. |
| `completed` | Every check that was supposed to run completed; one or more findings exist. |
| `partial` | At least one planned check did not complete (missing tool, parse failure, timeout, unavailable service) — coverage is visibly incomplete, whether or not findings exist. |
| `cancelled` | A user cancelled an in-flight run; evidence collected so far is preserved. |
| `budget_exhausted` | Cost/time limits were hit before planned checks completed; evidence collected so far is preserved. |

`clean` and `completed` are success outcomes, not errors — a fully covered
investigation is no less successful for having findings, and "no findings"
is a valid, reportable result. `partial`/`cancelled`/`budget_exhausted` must
never be presented to a user as `clean` or `completed`; the report's
completed-checks list is what distinguishes incomplete coverage, never the
presence of findings.

## Tool Integration Contract

Consumes RDR-073's shipped attachment/matching/provisioning/lifecycle
contract rather than re-implementing any part of it (validated against the
shipped code in
[the 2026-10-23 handoff-validation report](../../rdrs/audit-report-2026-10-23-rdr-075-m00-tool-handoff-validation.md)):

- **Native CLI analyzers** (the first delivery's primary path — Exhale,
  Knip, Debride, Vulture, PMD CPD, and similar gem/npm-installable or
  runtime-image-resident tools) may run through
  `AgentRun#execute_in_execution_environment`, the same contract
  `PreCommitRequirements::Evaluate` already uses, against the run's own
  pinned checkout, only after [#4604](https://github.com/viamin/paid/issues/4604)
  records the required live execution-environment evidence. That evidence must
  establish the selected analyzer's availability in the agent image and the
  checkout-access, invocation, bounded-output, exit-code, and cleanup behavior
  in a provisioned run. The shipped code establishes a candidate integration
  path; the host-only commands in the handoff audit do not make it
  implementation-ready.
- **`tool_sidecar` attachments** (RDR-073) remain scoped to analyzers that
  are themselves network-callable services and do not require full
  filesystem access to the checkout — RDR-073's sidecar `HostConfig`
  carries no bind mount, only network reachability by DNS alias and port
  (`PAID_TOOL_SIDECAR_ENDPOINTS`). A maintenance adapter that needs a
  sidecar-shaped analyzer sends it bounded request payloads (file content,
  diffs, symbol queries); it does not expect the sidecar to read the
  checkout itself.
- Matching for issue-less manual runs works today through
  `languages_include_any`, `repo_files_include_any`, explicit attachment, or
  `task_text_includes_any` — none of which require an issue. A rule scoped
  to `issue_labels_includes_any` correctly declines to match an issue-less
  run; that is expected behavior, not a gap.
- Resolution happens per relevant package/ecosystem for polyglot
  repositories, honoring project configuration and manual tool selections.
  A language match authorizes evidence collection only — never a blocking
  gate or an automatic fix.
- Where no applicable tool or native analyzer exists for the run's
  objective and repository, the run falls back to a prompt-only
  investigation: no tool check is "planned" for that run, so a completed
  prompt-only investigation with no findings reports `clean` (MAINT-044),
  while a tool check that *was* planned and then failed to run keeps
  forcing `partial` (MAINT-022).

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| New run type vs. custom prompt on an existing goal | New `"maintenance"` `AgentRun` goal | Custom prompts on existing creation goals | A custom prompt cannot represent report-only success, recurring finding identity, or a maintenance-shaped scope without overloading an unrelated goal's semantics (RDR-075 draft, Alternatives Considered). |
| Checkout access for batch analyzers | Subject to #4604's required live evidence, native CLI analyzers use `execute_in_execution_environment`; `tool_sidecar` is reserved for network-service-shaped analyzers | Require every analyzer to become a `tool_sidecar` network service; extend RDR-073 with a bind-mounted sidecar variant | The named first-delivery analyzers are CLI tools, not services, and static inspection identifies the existing execution-environment contract as the candidate path. #4604 must validate that path in the agent image before an adapter ships; a bind-mount extension is deferred unless that evidence shows a specific future recipe needs it. |
| Finding identity and report evidence | Project- and recipe-scoped canonical finding from claim + affected symbols, with immutable report-specific occurrences | A report-owned finding; line-number-based identity | Line numbers shift on unrelated edits, and a report-owned row cannot represent a recurring finding without destroying an earlier report. Canonical identity prevents duplicate repair work while immutable occurrences retain each pinned run's evidence (RDR-075 draft, Evidence and reporting). |
| Repair handoff | Separate, explicitly authorized issue/PR-creation run selecting specific findings | Automatic cleanup during the scan itself | Combining investigation with repair authorization risks oversized, unreviewed changes; keeping them separate makes the requested investigation and the authorized change both explicit (RDR-075 draft, Alternatives Considered). |

## Open Questions & Future Decisions

### Resolved

1. ✅ Issue-less manual runs can match RDR-073 tool attachments through
   language/repo-file/explicit/task-text conditions — same report.

### Deferred

1. Exact `MaintenanceReport`/`MaintenanceFinding`/
   `MaintenanceFindingOccurrence` column shapes and API response schemas
   (JSON structure, pagination) — resolve during #4328/#4329 implementation,
   not before design acceptance.
2. Whether `ScheduledMutationSweepJob`/`MutationSweeps::Run` migrate into a
   maintenance recipe — RDR-075 draft leaves this open; keep current sweep
   behavior unchanged until an explicit migration is designed.
3. Initial analyzer version pins and project-configuration defaults for the
   unnecessary-code recipe — belongs to #4330 once tool-assisted recipes are
   implemented and measured against prompt-only baselines.
4. A bind-mounted `tool_sidecar` variant for checkout-dependent network-service
   analyzers — not needed by any analyzer named in the current draft; file as
   upstream RDR-073 work only if a future recipe requires it.
5. Native CLI analyzer checkout access, invocation, bounded output, exit-code
   handling, and cleanup in the agent image — #4604 must record the required
   live execution-environment artifact before an implementation uses this
   candidate path. The handoff audit's host-only commands are not evidence for
   this decision.

## What This Is Not

- Not a tool marketplace, matching engine, or provisioning system — that is
  RDR-073's territory, consumed here, not duplicated.
- Not an automatic-repair mechanism — a scan never deletes source code or
  opens a PR as a side effect; repair is a separate, explicitly authorized
  run.
- Not a blocking PR-review gate — advisory PR integration (reusing
  maintenance evidence) is a later, separately approved policy decision,
  not part of this LLD's first-delivery scope.

## References

- [RDR-075 draft (PR #4308)](https://github.com/viamin/paid/pull/4308)
- [RDR-073: Marketplace Tool Sidecars](../../rdrs/RDR-073-marketplace-tool-sidecars.md)
  and its [LLD](../marketplace-tool-sidecars/marketplace-tool-sidecars-design.md)
- [layered-verification LLD](../layered-verification/layered-verification-design.md)
  — owns the optional scheduled-audit trigger contracts
  (`LAYERED-VERIFY-030`–`-032`) that consume this segment's scheduling
  contract (RDR-076 §2, [#4440](https://github.com/viamin/paid/issues/4440))
- [2026-10-23 tool-handoff validation report](../../rdrs/audit-report-2026-10-23-rdr-075-m00-tool-handoff-validation.md)
- `app/services/pre_commit_requirements/evaluate.rb` — shipped precedent for
  native CLI analyzer invocation inside the execution environment
- `app/models/agent_run.rb` — `execute_in_execution_environment`,
  `cleanup_execution_environment`
