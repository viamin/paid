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

## Optimization Recipe Family and Bounded Auto-Queue Policy

The optimization family is a recipe subset of the maintenance mechanism, not
a second run type or an enum embedded in a run. A code-defined catalog entry
has a stable key, display name, description, default metric hints, and a
pointer to a recipe definition when one exists. The initial menu is
performance, design/architecture, code duplication, security hardening,
cost/resource efficiency, maintainability/readability, and test
coverage/quality. New types are catalog/recipe entries. A selection that no
longer maps to a catalog entry degrades to the existing custom-objective
maintenance path; it does not reject an otherwise valid request.

The catalog menu is presentation over the run contract. UI, authenticated API,
and MCP start requests use the same project authorization and accept an
optional catalog selection alongside free-text scope and guidance. No scope
form limits the request to paths: a user may name files, a feature, a page, or
no scope. As elsewhere in maintenance, requested scope bounds recommendations,
not the supporting callers, tests, framework entry points, and design evidence
the assessment may inspect. Every selected catalog key and resolved recipe
version is snapshot data retained across retries.

The first implementation tranche is code duplication, maintainability, and
performance. Duplication and maintainability use available analyzer evidence
plus semantic assessment; similarity, complexity, or a missing static caller
is never alone evidence for consolidation or deletion. Performance is
prompt-first until an appropriate collector is available, and its report must
say so. Security, cost, architecture, and test-quality recipes are staged
follow-ons. Security findings remain report-only and manual-repair-only unless
a separate policy review authorizes another rule; test-quality work reconciles
with, rather than duplicates, RDR-075's test-quality recipe.

The #4495 owner decision is a narrow proposed exception to the base
manual-selection rule. At run start, an authorized user may elect auto-queue
for that one optimization run; omission is exactly report-only behavior. The
election snapshots a policy revision, the configured confidence selection
rule, and explicit maximum cost and time for each resulting repair. It is not
a tenant-wide switch, recipe default, schedule default, or authority to repair
outside selected findings.

`agent_harness` performs the semantic task: from bounded finding evidence,
counterevidence, and recipe context, it returns a structured assessment used
by the elected selection rule. Confidence is assessment metadata, not a
control-plane claim that a number is calibrated, universally comparable, or
semantically inferred by framework conditionals. The policy may snapshot a
threshold value and assessment-schema revision, but only `agent_harness`
assigns meaning to evidence; unavailable, malformed, or indeterminate
assessment is ineligible for auto-queue and remains visible for manual
selection.

Before creating a repair, deterministic gates verify the per-run election,
current maintenance admission policy, non-security category, open canonical
finding, explicit per-repair budgets, and a durable idempotency key derived
from the elected run and canonical finding identity. They invoke the existing
M04 repair pathway, retain report/finding provenance, preserve the finding's
bounded recommendation scope, and revalidate evidence against the repair
checkout when its revision differs from the report. A failed or stale
revalidation is a visible non-dispatch outcome, never a silent drop or a
repair authorization. Repeated occurrences of the same canonical finding do
not create duplicate auto-queued repair work. Disabling `maintenance_runs`
prevents new auto-queues but neither cancels admitted repair runs nor deletes
reports.

This policy is a reviewable prerequisite only. It maps to #4493–#4496 below;
#4492 is its tracking umbrella, not an executable deliverable. The policy is
not accepted merely because #4495 records the owner decisions. Before any
implementation, a human must accept these exact revisions and record that
decision in the Inbox/approval flow; until then this issue and its preparation
PR use `Tracks #4636` language and do not enable rollout.

## Storage Contract

A maintenance run is a new `AgentRun` goal (`"maintenance"`), not a new
model. Each run persists, immutably once started:

- `project_id`, the pinned repository revision (branch/SHA) the run
  investigated, and `issue_id` (nullable — issue-less manual runs are
  first-class).
- `objective` (the recipe key, or `nil` for a free-text user question),
  `scope` (optional paths/symbols the user named), and `guidance` (free-text
  instructions), captured verbatim at run start.
- `recipe_version` and the resolved tool versions/configuration actually
  used, for provenance (RDR-073 attachment metadata plus any native-CLI
  analyzer version string captured at invocation time).
- `cost_limit`/`time_limit` snapshots, consistent with existing run budget
  fields.
- For an optimization selection, the catalog key and its resolved recipe
  version; for an elected auto-queue policy, its policy and assessment-schema
  revisions, selection-rule value, and explicit per-repair cost/time caps.

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
| Optimization catalog | Code-defined extensible catalog and presentation menu over recipe keys | Hard enum or project-admin authoring UI | Recipe definitions remain the reusable execution contract; a catalog entry adds curated presentation and metric hints without migration churn or a new authoring authority (#4493). |
| Optimization auto-queue | Per-run, off-by-default pre-authorization after report completion, bounded by existing repair controls | Tenant/recipe default; repair during the scan | This is the precise #4495 owner decision. It retains report delivery and manual selection, while deterministic gates constrain a separately elected automation path. |
| Confidence handling | `agent_harness` semantic assessment plus deterministic selection-rule enforcement | Framework-calibrated numeric semantics or text heuristics | ZFC keeps evidence meaning with the agent. The control plane snapshots and enforces policy without pretending that a numerical score is calibrated (#4495). |

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
6. Human acceptance of the optimization catalog and precise #4495 auto-queue
   policy revision. Record an Inbox/approval decision against the merged
   canonical artifacts before implementation; #4636 remains open while this
   is pending.

## What This Is Not

- Not a tool marketplace, matching engine, or provisioning system — that is
  RDR-073's territory, consumed here, not duplicated.
- Not an automatic-repair mechanism — a scan never deletes source code or
  opens a PR as a side effect. The proposed optimization-only auto-queue rule
  still creates a separate, bounded, revalidated repair run through M04 and is
  off until accepted; all other repairs require explicit manual selection.
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
- [#4492](https://github.com/viamin/paid/issues/4492) — tracking umbrella;
  [#4493](https://github.com/viamin/paid/issues/4493),
  [#4494](https://github.com/viamin/paid/issues/4494),
  [#4495](https://github.com/viamin/paid/issues/4495), and
  [#4496](https://github.com/viamin/paid/issues/4496) — executable follow-on
  deliverables after acceptance
