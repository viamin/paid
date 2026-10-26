# EARS: General Maintenance Runs

> **Draft — pending design acceptance.** These specs trace to
> [`maintenance-runs-design.md`](maintenance-runs-design.md), itself a
> reviewable draft against the RDR-075 design from merged
> [PR #4308](https://github.com/viamin/paid/pull/4308) (still Status: Draft).
> All specs below are
> `[ ]` active gaps: correct, current intent with no implementation yet.
> None are implementable until RDR-075 is accepted and this LLD/EARS pair
> merges — see `docs/rdrs/RDR-075-general-maintenance-runs.md` §Implementation
> Plan step 1. Implementation phases are tracked at
> [#4328](https://github.com/viamin/paid/issues/4328)–[#4333](https://github.com/viamin/paid/issues/4333).

## Admission and Rollout Guard

- [ ] **MAINT-001**: The system shall define a `maintenance_runs` feature
      flag in `FeatureFlags::DEFINITIONS`, default off.
- [ ] **MAINT-002**: Where `maintenance_runs` is disabled for a project's
      tenant, the system shall refuse to admit a new maintenance run from
      the UI, API, and MCP surfaces identically.
- [ ] **MAINT-003**: Where `maintenance_runs` is disabled for a project's
      tenant, the system shall not dispatch any scheduled maintenance
      occurrence for that project.
- [ ] **MAINT-004**: While a `maintenance_runs` rollback is in effect, the
      system shall keep existing maintenance reports readable and existing
      active runs cancellable.

## Manual Investigation

- [ ] **MAINT-010**: The system shall allow an authorized user to start a
      maintenance run from a project without an associated issue, through the
      UI, the authenticated API, and the MCP surface, applying the same
      project-scoped start authorization on every surface.
- [ ] **MAINT-011**: The system shall accept an optional recipe objective, an
      optional scope (paths or symbols), and optional free-text guidance when
      starting a maintenance run, and shall require at least one recipe
      objective or nonblank free-text guidance; scope alone shall not admit a
      run.
- [ ] **MAINT-012**: When a user supplies named scope targets, the system
      shall resolve them before any check claims coverage of that scope.
- [ ] **MAINT-013**: If a named scope target is ambiguous or missing, then the
      system shall produce an actionable clarification outcome rather than
      silently broadening the run to a repository-wide scan.
- [ ] **MAINT-014**: Where no scope is supplied, the system shall record the
      run as an explicit broad-scope investigation rather than leaving scope
      ambiguous in the report.
- [ ] **MAINT-015**: The system shall persist the project, pinned repository
      revision, objective, scope, guidance, recipe version, and resolved
      tool versions/configuration on every maintenance run at start, and
      shall not mutate those fields after the run starts.
- [ ] **MAINT-016**: The system shall allow an authorized user to inspect a
      maintenance run, its terminal report, and its findings through the UI,
      authenticated API, and MCP surface, applying the same project-scoped
      inspection authorization on every surface.
- [ ] **MAINT-017**: The system shall allow an authorized user to cancel an
      in-flight maintenance run through the UI, authenticated API, and MCP
      surface, applying the same project-scoped cancellation authorization on
      every surface and preserving evidence already collected.
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
      only where [#4604](https://github.com/viamin/paid/issues/4604) has
      recorded the live execution-environment evidence establishing that
      analyzer's availability in the agent image and its checkout-access,
      invocation, bounded-output, exit-code, and cleanup behavior in a
      provisioned run.
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
      an explicit user selection.

## Optimization Recipe Family

- [ ] **MAINT-OPT-001**: The system shall provide the code-defined
      optimization catalog for #4493 with the initial Performance, Design /
      Architecture, Code Duplication, Security Hardening, Cost / Resource
      Efficiency, Maintainability / Readability, and Test Coverage & Quality
      entries, each carrying display metadata, objective information, metric
      hints, and a recipe reference when one exists.
- [ ] **MAINT-OPT-002**: When an authorized user starts an optimization
      maintenance run through the UI, authenticated API, or MCP surface, the
      system shall offer equivalent catalog selection and free-form
      scope/guidance inputs under the `maintenance_runs` guard.
- [ ] **MAINT-OPT-003**: When an optimization type is selected, the system
      shall snapshot that selection with the run and retain it across retries.
- [ ] **MAINT-OPT-004**: If a submitted optimization type has no catalog
      entry, then the system shall admit it only as the existing
      custom-objective maintenance path, rather than rejecting it or creating
      an enum-specific run contract.
- [ ] **MAINT-OPT-010**: When executing the #4494 Code Duplication,
      Maintainability / Readability, or Performance recipes, the system shall
      record recipe-specific evidence, counterevidence, coverage, and
      provenance under the MAINT report contract; a missing applicable tool
      shall remain visible rather than being represented as a clean tool scan.
- [ ] **MAINT-OPT-011**: When a duplicate-code or complexity collector emits
      a candidate, the system shall obtain the recommendation's semantic
      assessment through `agent_harness` and shall not treat similarity or a
      tool score alone as authority to consolidate code.
- [ ] **MAINT-OPT-012**: Where the #4494 Performance recipe has no credible
      applicable collector, the system shall complete a prompt-first
      investigation with prompt-only coverage disclosed in the report.
- [ ] **MAINT-OPT-013**: When assessing any optimization finding, the system
      shall preserve requested scope as a recommendation bound while recording
      supporting inspection outside that scope and requiring separate
      authorization for a broader repair.
- [ ] **MAINT-OPT-014**: When a repeated optimization scan observes the same
      project-, recipe-, claim-, and symbol-scoped finding, the system shall
      create a new occurrence under the existing canonical finding rather than
      duplicate repair work.
- [ ] **MAINT-OPT-020**: When an authorized user explicitly elects #4495
      auto-queue at optimization-run start, the system shall snapshot the
      election, its confidence-threshold policy input, and explicit per-repair
      cost/time caps; omission shall preserve report-only manual selection.
- [ ] **MAINT-OPT-021**: When an auto-queue election is evaluated, the system
      shall obtain semantic eligibility and confidence assessment through a
      structured `agent_harness` response and shall not derive calibrated
      confidence from tool output or control-plane text heuristics.
- [ ] **MAINT-OPT-022**: Before auto-queueing an elected optimization repair,
      the system shall deterministically require current `maintenance_runs`
      admission, existing repair-pathway authorization, explicit budgets, a
      qualifying policy assessment, and an optimization finding outside the
      Security Hardening category.
- [ ] **MAINT-OPT-023**: If the selected finding's repair target revision has
      moved since its report occurrence, then the system shall revalidate the
      evidence against the repair checkout before dispatching an auto-queued
      repair and shall surface a failed revalidation without dispatch.
- [ ] **MAINT-OPT-024**: When an auto-queued repair would duplicate an active
      or queued repair for the same canonical finding identity and repair
      lineage, the system shall not dispatch the duplicate.
- [ ] **MAINT-OPT-025**: When an auto-queued repair exhausts its explicit
      cost or time cap, the system shall preserve collected evidence and
      report the bounded exhaustion through the maintenance repair contract.
- [ ] **MAINT-OPT-026**: The system shall retain report and canonical-finding
      provenance on every auto-queued repair and shall make every failed
      authorization, budget, revalidation, or idempotency gate visible.
- [ ] **MAINT-OPT-027**: When `maintenance_runs` is disabled after an
      auto-queue election, the system shall refuse new auto-queued repair
      dispatches without cancelling active repairs or deleting reports.
- [ ] **MAINT-OPT-030**: When #4496 adds Security Hardening recipes, the
      system shall keep their findings report-only and manual-repair-selection
      only until a dedicated safety and accuracy policy is accepted.
- [ ] **MAINT-OPT-031**: When #4496 adds Cost / Resource Efficiency or Design
      / Architecture recipes without credible applicable tools, the system
      shall use prompt-first evidence and disclose that coverage honestly.
- [ ] **MAINT-OPT-032**: When #4496 adds Test Coverage & Quality, the system
      shall reconcile its recipe and evidence contract with RDR-075's planned
      test-quality objective rather than creating a competing maintenance
      contract.
- [ ] **MAINT-OPT-033**: The system shall not implement the optimization
      catalog, recipes, or auto-queue policy until the owner accepts and the
      repository merges the exact RDR-075 and maintenance LLD/EARS revisions;
      this preparation does not enable rollout.
