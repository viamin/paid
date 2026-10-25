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
      an explicit user selection or a recorded opt-in auto-queue policy that
      satisfies MAINT-086 through MAINT-090.

## Optimization Recipe Family and Bounded Auto-Queue

- [ ] **MAINT-080**: The system shall expose a code-defined optimization
      catalog with Performance, Design / Architecture, Code Duplication,
      Security Hardening, Cost / Resource Efficiency, Maintainability /
      Readability, and Test Coverage & Quality entries; each entry shall
      provide a display name, investigation description, default metric hints,
      and an optional recipe-definition reference.
- [ ] **MAINT-081**: The system shall permit an authorized user to start a
      maintenance run with or without an optimization catalog selection through
      the UI, authenticated API, and MCP surface with equivalent authorization,
      and shall retain a selected type and resolved recipe in the immutable run
      snapshot across retries.
- [ ] **MAINT-082**: If a submitted optimization type has no catalog entry,
      then the system shall preserve it as a custom-objective maintenance run
      rather than reject the request or coerce it to another recipe.
- [ ] **MAINT-083**: The system shall treat requested optimization scope as a
      bound on recommendations and repairs, not on supporting evidence
      inspection, and shall disclose out-of-scope supporting inspection and
      coverage limitations in the report.
- [ ] **MAINT-084**: The system shall obtain semantic finding assessment only
      through `agent_harness`, including supporting evidence,
      counterevidence, verification disposition, and an ordered qualitative
      repair-confidence level, and shall not represent that level as a
      calibrated numeric probability or derive it from keywords, labels, or
      raw tool scores.
- [ ] **MAINT-085**: The system shall make Code Duplication,
      Maintainability / Readability, and Performance recipe reports preserve
      their collector provenance and honestly identify prompt-only or partial
      coverage; similarity, complexity, or absent static references alone
      shall not establish a repair recommendation.
- [ ] **MAINT-086**: The system shall leave automatic repair disabled unless
      an authorized user elects an auto-queue policy for that run at start;
      the election, ordered confidence threshold, and explicit per-repair cost
      and time caps shall be immutable run-snapshot data, and omission shall
      preserve report-only behavior.
- [ ] **MAINT-087**: On report completion, the system shall auto-queue a
      repair only through the existing authorized repair pathway when the
      `maintenance_runs` guard permits new admission, a recorded election
      exists, the structured `agent_harness` assessment meets the elected
      ordered threshold, the finding is open and current, the repair remains
      bounded to that finding, the explicit budget is valid, and no repair
      with the same finding identity and policy snapshot was previously
      auto-queued.
- [ ] **MAINT-088**: When an auto-queue candidate fails an authorization,
      guard, threshold, category, freshness, scope, budget, or idempotency
      gate, the system shall retain the report and record a visible
      non-dispatch reason without creating repair work.
- [ ] **MAINT-089**: The system shall link each auto-queued repair to its
      source report, finding, policy snapshot, and budget; if its repair
      checkout has moved or the finding evidence is stale, the system shall
      require visible revalidation before applying the recommendation.
- [ ] **MAINT-090**: The system shall exclude Security Hardening findings
      from auto-queue and allow their repair only through manual selection
      until a separately accepted security-repair policy authorizes a narrower
      exception.
