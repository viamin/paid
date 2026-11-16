# EARS: General Maintenance Runs

> **Accepted intent.** These specs trace to
> [`maintenance-runs-design.md`](maintenance-runs-design.md) and the
> [RDR-075 owner decision](https://github.com/viamin/paid/issues/4635#issuecomment-6901990906).
> All specs below are `[ ]` active implementation gaps. Delivery remains
> subject to each issue's dependencies and the default-off rollout guard.
> Implementation phases are tracked at
> [#4328](https://github.com/viamin/paid/issues/4328)–[#4333](https://github.com/viamin/paid/issues/4333).

## Admission and Rollout Guard

- [x] **MAINT-001**: The system shall define a `maintenance_runs` feature
      flag in `FeatureFlags::DEFINITIONS`, default off.
      *Tests:* `spec/services/feature_flags_maintenance_runs_spec.rb`
      *Code:* `app/services/feature_flags.rb` (#4328)

- [x] **MAINT-002**: Where `maintenance_runs` is disabled for a project's
      tenant, the system shall refuse to admit a new maintenance run from
      the UI, API, and MCP surfaces identically.
      *Tests:* `spec/requests/projects/maintenance_runs_spec.rb`, `spec/mcp/tools/start_maintenance_run_spec.rb`
      *Code:* `app/services/maintenance_runs/start.rb` (shared admission gate), `app/controllers/projects/maintenance_runs_controller.rb` (#4328)

- [ ] **MAINT-003**: Where `maintenance_runs` is disabled for a project's
      tenant, the system shall not dispatch any scheduled maintenance
      occurrence for that project. *(Scheduled dispatch ships with #4332; the
      flag registration from M01 already gates it.)*

- [x] **MAINT-004**: While a `maintenance_runs` rollback is in effect, the
      system shall keep existing maintenance reports readable and existing
      active runs cancellable.
      *Tests:* `spec/requests/projects/maintenance_runs_spec.rb`
      *Code:* `app/views/projects/agent_runs/show.html.erb`, `app/views/agent_runs/_maintenance_context.html.erb` (inspection never consults the guard) (#4328)

## Manual Investigation

- [x] **MAINT-010**: The system shall allow an authorized user to start a
      maintenance run from a project without an associated issue, through the
      UI, the authenticated API, and the MCP surface, applying the same
      project-scoped start authorization on every surface.
      *Tests:* `spec/requests/projects/maintenance_runs_spec.rb`, `spec/mcp/tools/start_maintenance_run_spec.rb`
      *Code:* `app/services/maintenance_runs/start.rb`, `app/controllers/projects/maintenance_runs_controller.rb`, `app/mcp/tools/start_maintenance_run.rb` (#4328)

- [x] **MAINT-011**: The system shall accept an optional recipe objective, an
      optional scope (paths, symbols, or a free-form natural-language target),
      and optional free-text guidance when starting a maintenance run, and
      shall require at least one recipe objective or nonblank free-text
      guidance; scope alone shall not admit a run.
      *Tests:* `spec/services/maintenance_runs/start_spec.rb`, `spec/models/agent_run_maintenance_spec.rb`
      *Code:* `app/services/maintenance_runs/start.rb`, `app/services/maintenance_runs/recipes.rb`, `app/models/agent_run.rb` (#4328)

- [x] **MAINT-012**: When a user supplies named scope targets, the system
      shall resolve them before any check claims coverage of that scope.
      *Tests:* `spec/services/maintenance_runs/build_prompt_spec.rb`
      *Code:* `app/services/maintenance_runs/build_prompt.rb` (investigation contract embedded in every maintenance prompt) (#4328)

- [x] **MAINT-013**: If a named scope target is ambiguous or missing, then the
      system shall produce an actionable clarification outcome rather than
      silently broadening the run to a repository-wide scan.
      *Tests:* `spec/services/maintenance_runs/build_prompt_spec.rb`
      *Code:* `app/services/maintenance_runs/build_prompt.rb` (#4328; report-outcome durability lands with #4329)

- [x] **MAINT-014**: Where no scope is supplied, the system shall record the
      run as an explicit broad-scope investigation rather than leaving scope
      ambiguous in the report.
      *Tests:* `spec/services/maintenance_runs/start_spec.rb`, `spec/services/maintenance_runs/build_prompt_spec.rb`
      *Code:* `app/services/maintenance_runs/start.rb` (`maintenance_scope_kind`), `app/services/maintenance_runs/build_prompt.rb` (#4328)

- [x] **MAINT-015**: The system shall resolve and persist the project default
      branch's commit SHA at admission as the pinned repository revision,
      objective, scope, guidance, recipe version, and resolved
      tool versions/configuration on every maintenance run at start, and
      shall not mutate those fields after the run starts.
      *Tests:* `spec/models/agent_run_maintenance_spec.rb`, `spec/services/maintenance_runs/start_spec.rb`, `spec/services/agent_runs/manual_run_retry_policy_spec.rb`
      *Code:* `app/models/agent_run.rb`, `app/services/maintenance_runs/start.rb`, `app/services/agent_runs/manual_run_retry_policy.rb` (#4328; resolved analyzer-version provenance lands with #4330)

- [ ] **MAINT-016**: The system shall allow an authorized user to inspect a
      maintenance run, its terminal report, and its findings through the UI,
      authenticated API, and MCP surface, applying the same project-scoped
      inspection authorization on every surface. *(M01 shipped run/context
      inspection on UI and MCP — `spec/requests/projects/maintenance_runs_spec.rb`,
      `app/mcp/tools/get_agent_run.rb`; terminal-report and findings
      inspection lands with the #4329 report model.)*

- [x] **MAINT-017**: The system shall allow an authorized user to cancel an
      in-flight maintenance run through the UI, authenticated API, and MCP
      surface, applying the same project-scoped cancellation authorization on
      every surface and preserving evidence already collected.
      *Tests:* `spec/requests/projects/maintenance_runs_spec.rb` (UI cancel, incl. during rollback), `spec/temporal/activities/complete_maintenance_run_activity_spec.rb` (evidence preservation)
      *Code:* shared cancel paths (`AgentRunCancellable`, `Tools::CancelAgentRun`) over `AgentRunPolicy#cancel?`; `app/temporal/activities/complete_maintenance_run_activity.rb` (#4328)
- [ ] **MAINT-018**: The system shall allow an authorized user to select
      findings for bounded repair work through the UI, authenticated API, and
      MCP surface, applying the same project-scoped selection authorization
      on every surface and the existing authorization of the selected repair
      creation pathway.

## Reports and Findings

- [ ] **MAINT-020**: The system shall produce exactly one `MaintenanceReport`
      per maintenance run, with a terminal outcome of `clean`, `completed`,
      `partial`, `cancelled`, or `budget_exhausted`, and shall preserve that
      report's finding occurrences and evidence after later scans complete.
      `clean` and `completed` are success outcomes: `completed` means every
      planned check completed with one or more findings, and `partial` is
      reserved for runs where at least one planned check did not complete.
- [ ] **MAINT-021**: The system shall record, for every maintenance report,
      which checks actually completed and which did not, independent of
      whether findings exist.
- [ ] **MAINT-022**: If any planned check does not complete (missing tool,
      parse failure, timeout, or unavailable dependency), then the system
      shall report `partial`, never `clean` or `completed`; where every
      planned check completed and one or more findings exist, the system
      shall report `completed`, never `partial`.
- [ ] **MAINT-023**: When a maintenance run is cancelled, the system shall
      preserve all evidence collected up to cancellation and report
      `cancelled`.
- [ ] **MAINT-024**: When a maintenance run exhausts its cost or time budget,
      the system shall preserve all evidence collected up to that point and
      report `budget_exhausted`.
- [ ] **MAINT-025**: The system shall record, for every report-specific
      finding occurrence, its canonical finding, its
      category, affected locations/symbols, claim, supporting evidence,
      known counterevidence, proposed action, validation plan, and a
      verification disposition distinct from any raw tool-confidence score.
- [ ] **MAINT-026**: The system shall derive finding identity from its
      project, recipe, claim, and affected symbols, not from line numbers
      alone.
- [ ] **MAINT-027**: When a repeated scan reproduces a finding with the same
      identity, the system shall retain one canonical finding, create a new
      occurrence linked to the current report, and shall not overwrite or
      reattach an occurrence from an earlier report.
- [ ] **MAINT-028**: When a user dismisses a finding, the system shall
      require and persist a dismissal reason.
- [ ] **MAINT-029**: If a dismissed finding's supporting evidence materially
      changes on a later scan, then the system shall mark it for
      reassessment rather than leaving it silently dismissed.

## Tool Integration

- [ ] **MAINT-040**: The system shall invoke native CLI analyzers through
      `AgentRun#execute_in_execution_environment` against the run's pinned
      checkout, without provisioning a `tool_sidecar` for that analyzer,
      using the live execution-environment path validated in
      [#4604](https://github.com/viamin/paid/issues/4604). Before selecting
      an additional analyzer, the recipe shall verify that analyzer's
      availability and supported invocation in the agent image.
- [ ] **MAINT-041**: The system shall resolve RDR-073 marketplace tool
      attachments for a maintenance run using the same matching contract
      (language, repository-file, explicit attachment, task-text, and
      optional issue-label conditions) that any other run goal uses, with no
      maintenance-specific matching engine.
- [ ] **MAINT-042**: Where a repository is polyglot, the system shall resolve
      applicable analyzer capabilities per relevant package/ecosystem rather
      than applying one tool's results repository-wide.
- [ ] **MAINT-043**: The system shall record the resolved analyzer
      name/version/configuration as provenance on every finding and report
      that used it.
- [ ] **MAINT-044**: If no applicable tool or native analyzer exists for the
      run's objective and repository, then the system shall fall back to a
      prompt-only investigation rather than failing the run outright.
- [ ] **MAINT-045**: The system shall not treat a language or repository-file
      match alone as authorization for an automatic fix or a blocking gate.

## Recurring Maintenance and Repair Handoff

- [ ] **MAINT-060**: The system shall allow a project to configure a
      maintenance schedule with the same objective/scope/guidance/limits
      shape and objective admission rule as a manual run, opt-in and default
      disabled.
- [ ] **MAINT-061**: The system shall expose each maintenance schedule's
      timezone and next scheduled occurrence.
- [ ] **MAINT-062**: While an equivalent maintenance run for a schedule is
      already in flight, the system shall not dispatch an overlapping
      occurrence for that schedule.
- [ ] **MAINT-063**: The system shall bound missed-occurrence catchup for a
      maintenance schedule rather than replaying an unbounded backlog.
- [ ] **MAINT-064**: When a user disables a maintenance schedule, the system
      shall stop future dispatch without cancelling any already-active run
      or deleting any prior report.
- [ ] **MAINT-070**: The system shall allow an authorized user to select one
      or more open findings from a maintenance report to create a bounded
      repair issue or PR-creation run through existing authorized creation
      pathways.
- [ ] **MAINT-071**: If the repair target's revision has changed since the
      source report was generated, then the system shall require
      revalidation of the selected finding's evidence before applying its
      recommendation.
- [ ] **MAINT-072**: The system shall link every repair issue/PR-creation run
      back to its source maintenance report and finding.
- [ ] **MAINT-073**: The system shall never create a repair issue or
      PR-creation run as a direct side effect of a maintenance scan without
      an explicit user selection; an explicit election captured at run start
      counts as such a selection, and that election is itself never a
      tenant-wide, project-wide, or recipe-wide setting.

## Advisory PR Audit and Closeout

- [ ] **MAINT-080**: When auditing a pull request, the system shall compare
      the actual base and head revisions and report only findings introduced
      or worsened by that comparison.
- [ ] **MAINT-081**: The system shall retain pre-existing debt in maintenance
      reporting and publish PR-audit evidence through the existing review
      publication lifecycle without duplicate or stale-head reviews.
- [ ] **MAINT-082**: Where PR-audit tool evidence requires execution, the
      system shall collect it inside the established isolated execution
      boundary and shall not infer analyzer execution from the no-container
      review pilot.
- [ ] **MAINT-083**: The system shall keep PR-audit findings advisory unless
      a separately accepted policy and analyzer-specific accuracy and
      failure-handling evidence authorize a blocking gate.
- [ ] **MAINT-090**: At closeout, the system shall audit every accepted MAINT
      claim against shipped behavior, tests, and required human or external
      evidence; it shall record each remaining gap as an explicit dependency
      and shall not infer completion from closed child issues.
- [ ] **MAINT-091**: The closeout shall preserve the `maintenance_runs`
      default-off admission guard and opt-in recurring schedules unless an
      evidence-backed RDR closeout decision explicitly changes them.

## Implementation Slice Traceability

| Task | Assigned claims |
| --- | --- |
| [#4328](https://github.com/viamin/paid/issues/4328) (M01) | MAINT-001–002, MAINT-004, MAINT-010–017 |
| [#4329](https://github.com/viamin/paid/issues/4329) (M02) | MAINT-020–029 |
| [#4330](https://github.com/viamin/paid/issues/4330) (M03) | MAINT-040–045 |
| [#4331](https://github.com/viamin/paid/issues/4331) (M04) | MAINT-018, MAINT-070–073 |
| [#4332](https://github.com/viamin/paid/issues/4332) (M05) | MAINT-003, MAINT-060–064 |
| [#4333](https://github.com/viamin/paid/issues/4333) (M06) | MAINT-080–083 |
| [#4334](https://github.com/viamin/paid/issues/4334) (C75) | MAINT-090–091 |

MAINT-004 is shared rollout preservation work: M01 implements readable
reports and cancellable active runs during rollback; later slices must retain
that behavior. This table assigns implementation and closeout accountability;
it does not authorize runtime work before #4635 has an owner acceptance
record.
