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
> MAINT-080–097 below are a preparation-only, pending-acceptance optimization
> policy. They `Track` [#4636](https://github.com/viamin/paid/issues/4636) and
> [#4492](https://github.com/viamin/paid/issues/4492); neither tracking issue
> is an executable deliverable or authorization to implement, auto-queue, or
> roll out repairs.

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
      PR-creation run as a direct side effect of a report-only maintenance
      scan without an explicit user selection; the only proposed exception is
      an owner-accepted MAINT-087–094 auto-queue election.

## Optimization Recipe Catalog and Bounded Repair Policy

### Catalog and selection — #4493

- [ ] **MAINT-080**: The system shall represent each optimization type as a
      code-defined catalog/recipe entry with a stable key, display text,
      investigation instructions, evidence-collector applicability,
      validation guidance, and metric hints, so adding a type does not require
      an enum migration.
- [ ] **MAINT-081**: The system shall provide Performance, Design /
      Architecture, Code Duplication, Security Hardening, Cost / Resource
      Efficiency, Maintainability / Readability, and Test Coverage & Quality
      as the initial optimization catalog entries.
- [ ] **MAINT-082**: The system shall offer optional optimization-type
      selection with equivalent project-scoped authorization through the UI,
      authenticated API, and MCP surfaces; it shall continue to admit a
      free-text maintenance objective without a selection.
- [ ] **MAINT-083**: When an optimization type is selected, the system shall
      snapshot its key and entry version with the run and retain it on retries;
      when a supplied type is not cataloged, the system shall retain it as a
      custom objective rather than rejecting the run.

### First recipes and honest assessment — #4494

- [ ] **MAINT-084**: The system shall define Code Duplication,
      Maintainability / Readability, and Performance recipes using the
      catalog contract, and shall preserve tool/version provenance whenever an
      evidence collector contributes to a finding.
- [ ] **MAINT-085**: Where an optimization recipe has no credible applicable
      evidence collector, the system shall complete it as a prompt-first
      investigation and shall disclose that coverage basis in its report.
- [ ] **MAINT-086**: The system shall obtain semantic finding assessment,
      evidence/counterevidence consideration, verification disposition, and
      policy-requested confidence through `agent_harness`; application code
      shall not infer recommendation eligibility from keywords, raw tool
      output, or a locally calibrated confidence formula.

### Opt-in bounded auto-queue — #4495

- [ ] **MAINT-087**: The system shall default optimization maintenance runs
      to report-only and shall allow an authorized user to elect auto-queueing
      only at run start, with an explicit confidence threshold and per-repair
      cost/time budgets snapshotted through equivalent UI, authenticated API,
      and MCP contracts.
- [ ] **MAINT-088**: When the report completes, the system shall leave all
      findings visible and shall consider auto-queueing only findings whose
      structured agent assessment satisfies the stored run-start selection
      policy; the system shall treat that threshold as a deterministic policy
      gate, not as proof that confidence is calibrated or semantically
      sufficient by itself.
- [ ] **MAINT-089**: The system shall dispatch an auto-queued repair only
      through the existing MAINT-070 authorized repair pathway, preserving its
      report/finding provenance, finding-bounded scope, and explicit
      per-repair budgets.
- [ ] **MAINT-090**: The system shall require MAINT-071 revalidation before
      an auto-queued repair may apply a recommendation to a checkout whose
      revision differs from the source report's pinned revision.
- [ ] **MAINT-091**: The system shall enforce auto-queue idempotency by
      refusing to create duplicate repair work for the same source
      report/finding identity lineage.
- [ ] **MAINT-092**: The system shall surface a stale, unavailable,
      unauthorized, idempotently suppressed, or budget-exhausted auto-queue
      gate outcome without silently dropping it, broadening scope, or
      bypassing the gate.
- [ ] **MAINT-093**: Where `maintenance_runs` is disabled, the system shall
      admit no new optimization auto-queue election or repair dispatch while
      preserving reports and without cancelling already-active repair runs.
- [ ] **MAINT-094**: The system shall preserve evidence collected by an
      auto-queued repair that exhausts its explicit cost or time budget and
      shall report that exhaustion through the existing maintenance outcome
      contract.

### Staged follow-ons and security boundary — #4496

- [ ] **MAINT-095**: The system shall keep Security Hardening findings
      report-only and available for manual MAINT-070 selection, and shall
      exclude them from auto-queue until a separately accepted safety and
      accuracy policy explicitly authorizes them.
- [ ] **MAINT-096**: The system shall treat Cost / Resource Efficiency,
      Design / Architecture, and Test Coverage & Quality as staged catalog
      recipes, each using the MAINT-084–086 evidence and honest-coverage
      contract.
- [ ] **MAINT-097**: Before defining the Test Coverage & Quality recipe, the
      system shall reconcile it with RDR-075's planned test-quality objective
      so the two do not create duplicate maintenance behaviors.
