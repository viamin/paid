# EARS: Optimization Recipes

> **Draft — pending design acceptance.** These specs trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md), itself
> a reviewable draft against the
> [RDR-075 design](../../rdrs/RDR-075-general-maintenance-runs.md)
> (Status: Draft). All specs below are `[ ]` active gaps: correct, current
> intent with no implementation yet. None are implementable until this
> LLD/EARS pair is accepted and merged, and until the base maintenance
> contracts in [`docs/intent/maintenance-runs/`](../maintenance-runs/maintenance-runs-specs.md)
> are accepted. Each section names the delivery issue that owns its claims;
> [#4492](https://github.com/viamin/paid/issues/4492) is the tracking umbrella
> and owns none of them.

## Catalog and Type Menu — [#4493](https://github.com/viamin/paid/issues/4493)

- [ ] **MAINT-OPT-001**: The system shall define the optimization recipe
      catalog as a code-defined registry whose entries each carry a stable
      identifier, a display name, a description of what the agent looks for,
      default metric hints, a pointer to a recipe definition when one
      exists, and a repair standing.
- [ ] **MAINT-OPT-002**: The optimization recipe catalog shall contain the
      seven initial types: Performance, Design/Architecture, Code Duplication,
      Security Hardening, Cost/Resource Efficiency, Maintainability/Readability,
      and Test Coverage & Quality.
- [ ] **MAINT-OPT-003**: Adding an optimization type to the optimization
      recipe catalog shall require a catalog entry only, and shall not
      require an enum change or a database migration.
- [ ] **MAINT-OPT-004**: Where a maintenance run is started, the system shall
      surface the optimization type menu on the UI, the authenticated API, and
      the MCP surface with equivalent entries and equivalent project-scoped
      start authorization.
- [ ] **MAINT-OPT-005**: Where a maintenance run is started without an
      optimization type, the system shall start the run as a custom-objective
      investigation and shall not fail the start.
- [ ] **MAINT-OPT-006**: Where a maintenance run is started with an
      optimization type value that is not present in the optimization recipe
      catalog, the system shall start the run as a custom-objective
      investigation, shall record the unmapped value on the run, and shall
      not fail the start.
- [ ] **MAINT-OPT-007**: The system shall record the selected optimization
      type identifier on the maintenance run snapshot alongside the objective,
      scope, and guidance, and shall not mutate it after the run starts.
- [ ] **MAINT-OPT-008**: The system shall retain the selected optimization
      type identifier, and any recorded unmapped value, across retries of the
      same maintenance run.
- [ ] **MAINT-OPT-009**: Where the `maintenance_runs` rollout guard is
      disabled for a project's tenant, the system shall refuse to admit a
      maintenance run that selects an optimization type from the UI, the
      authenticated API, and the MCP surface identically.

## Scope — [#4493](https://github.com/viamin/paid/issues/4493), [#4494](https://github.com/viamin/paid/issues/4494)

- [ ] **MAINT-OPT-010**: The system shall accept an optimization run's scope
      as paths, symbols, or a free-form natural-language target, and shall
      not impose a limit on the breadth of a natural-language scope.
- [ ] **MAINT-OPT-011**: Where an optimization run's scope names a
      natural-language target, the system shall resolve that target before
      any check claims coverage of it.
- [ ] **MAINT-OPT-012**: The system shall record the resolved scope actually
      investigated and any exclusions on the maintenance report, distinct from
      the scope the user requested.
- [ ] **MAINT-OPT-013**: Scope shall bound the recommendations an
      optimization report makes, and shall not bound the supporting evidence
      an optimization investigation may inspect.
- [ ] **MAINT-OPT-014**: Where an optimization finding's proposed action
      extends beyond the requested scope, the system shall mark that proposed
      action as requiring explicit human authorization, and shall not treat it
      as eligible for automatic repair.

## Recipe Execution and Honest Evidence — [#4494](https://github.com/viamin/paid/issues/4494)

- [ ] **MAINT-OPT-015**: Each optimization recipe definition shall supply an
      objective, investigation instructions, the applicable evidence
      collectors, validation guidance, and default metric hints.
- [ ] **MAINT-OPT-016**: Where an optimization recipe attaches a tool, the
      system shall record the analyzer name, version, and configuration as
      provenance on every finding and report that used it.
- [ ] **MAINT-OPT-017**: Where no applicable tool or native analyzer exists
      for an optimization recipe and the run's repository, the system shall
      complete the investigation prompt-first and shall disclose in the
      maintenance report that no tool evidence was collected.
- [ ] **MAINT-OPT-018**: The system shall not recommend an optimization
      finding's code for consolidation or deletion solely from duplication
      analyzer output, and shall record in that finding the deliberate
      independence, framework callback, or dynamic invocation it considered.
- [ ] **MAINT-OPT-019**: The system shall record for each optimization
      finding its category, affected locations and symbols, claim, supporting
      evidence, known counterevidence, proposed action, validation plan, and a
      verification disposition distinct from any raw tool-confidence score.
- [ ] **MAINT-OPT-020**: The system shall record the recipe's default metric
      hints on the optimization findings that recipe produces.
- [ ] **MAINT-OPT-021**: Where an optimization investigation completes every
      planned check and produces no findings, the system shall report a
      successful clean outcome.
- [ ] **MAINT-OPT-022**: Where a repeated optimization scan observes a
      finding with the same canonical finding identity, the system shall
      update that canonical finding's occurrence rather than producing
      duplicate repair work.
- [ ] **MAINT-OPT-023**: The system shall record, for each optimization
      recipe, the evaluation evidence measured against at least one project
      outside Paid's own repository, covering actionable findings, false
      positives, unresolved coverage, latency, token and tool cost, and
      repeated-finding noise.

## Semantic Repair-Eligibility Assessment — [#4495](https://github.com/viamin/paid/issues/4495)

- [ ] **MAINT-OPT-024**: The system shall obtain an optimization finding's
      repair-eligibility standing from a structured `agent_harness`
      assessment against a versioned rubric, and shall not derive that
      standing from the finding's text, its category string, a raw analyzer
      confidence score, or any other pattern match over analyzer output.
- [ ] **MAINT-OPT-025**: The repair-eligibility assessment result shall record
      the canonical finding it assessed, the rubric version, the standing, an
      explanation, and the citations the assessment relied on.
- [ ] **MAINT-OPT-026**: The repair-eligibility standing shall be one of
      `strong`, `supported`, `exploratory`, `insufficient`, or `unknown`.
- [ ] **MAINT-OPT-027**: The system shall compare repair-eligibility
      standings by their defined order, and shall not convert a standing into
      a numeric score.
- [ ] **MAINT-OPT-028**: Where a repair-eligibility assessment returns the
      standing `unknown`, the system shall treat the finding as not
      qualifying for automatic repair under any configuration.
- [ ] **MAINT-OPT-029**: Where a repair-eligibility assessment is absent,
      malformed, of an unknown rubric version, or bound to a different
      finding occurrence, the system shall treat the finding as not qualifying
      for automatic repair and shall not substitute any other standing.
- [ ] **MAINT-OPT-030**: Where the evidence an optimization finding
      occurrence recorded has materially changed, the system shall treat the
      assessment bound to that occurrence as no longer applicable and shall
      re-assess rather than act on it.

## Bounded Automatic Repair — [#4495](https://github.com/viamin/paid/issues/4495)

- [ ] **MAINT-OPT-031**: Automatic repair shall be off by default, shall be
      elected per maintenance run at run start, and shall never be enabled by
      a tenant-wide, project-wide, or recipe-wide default.
- [ ] **MAINT-OPT-032**: Where a maintenance run does not elect automatic
      repair, the system shall behave exactly as a report-only run.
- [ ] **MAINT-OPT-033**: Where a maintenance run may be started, the system
      shall surface the automatic-repair election, the configured minimum
      standing, and the default per-repair cost and time caps on the UI, the
      authenticated API, and the MCP surface with equivalent authorization.
- [ ] **MAINT-OPT-034**: The system shall record the automatic-repair
      election, the minimum standing in effect at run start, and the
      per-repair cost and time caps on the maintenance run snapshot, and shall
      not mutate them after the run starts.
- [ ] **MAINT-OPT-035**: The default minimum standing for automatic repair
      shall be `supported`.
- [ ] **MAINT-OPT-036**: Where a run-start election sets a minimum standing,
      the system shall apply the stricter of the elected minimum standing and
      the configured default minimum standing.
- [ ] **MAINT-OPT-037**: The system shall not permit a maintenance schedule
      to elect automatic repair.
- [ ] **MAINT-OPT-038**: Each optimization type's repair standing shall be
      one of `auto_eligible`, `manual_only`, or `default_deny`.
- [ ] **MAINT-OPT-039**: The system shall change an optimization type's
      repair standing only through a separate owner authorization recorded
      against the optimization recipe catalog, and shall never widen a repair
      standing through a run-start election.
- [ ] **MAINT-OPT-040**: The system shall dispatch an automatically selected
      repair only where the source maintenance report's outcome is
      `completed`.
- [ ] **MAINT-OPT-041**: Where the source maintenance report's outcome is
      `partial`, `cancelled`, or `budget_exhausted`, the system shall
      dispatch no automatic repair and shall record why no dispatch occurred.
- [ ] **MAINT-OPT-042**: The system shall deliver the full maintenance
      report regardless of which findings were selected for automatic repair,
      and shall leave unselected findings available for manual selection.
- [ ] **MAINT-OPT-043**: The system shall dispatch an automatically selected
      repair through the base maintenance repair-handoff pathway unchanged,
      and shall link the repair run to the source maintenance report and the
      canonical finding identity.
- [ ] **MAINT-OPT-044**: Where the repair target's revision has moved since
      the source maintenance report was generated, the system shall require
      revalidation of the finding's evidence against the repair checkout
      before the repair applies, and shall surface a revalidation failure
      visibly rather than dropping the repair silently.
- [ ] **MAINT-OPT-045**: The system shall not dispatch a second automatic
      repair for a canonical finding identity that already has a queued or
      completed automatic repair run.
- [ ] **MAINT-OPT-046**: Each automatically dispatched repair run shall carry
      explicit cost and time caps, and where those caps are exhausted the
      system shall preserve the evidence collected so far and report the
      exhaustion.
- [ ] **MAINT-OPT-047**: The scope of an automatically dispatched repair
      shall be bounded to the approved finding, and any proposed action
      extending beyond that finding shall require explicit human
      authorization.
- [ ] **MAINT-OPT-048**: Where the `maintenance_runs` rollout guard is
      disabled for a project's tenant, the system shall queue no new
      automatic repair run, and shall neither cancel an in-flight repair run
      nor delete any maintenance report.

## Staged Optimization Types — [#4496](https://github.com/viamin/paid/issues/4496)

- [ ] **MAINT-OPT-049**: Each staged optimization type shall register through
      the optimization recipe catalog with its metadata, applicable evidence
      collectors, and default metric hints, and shall not require an enum
      change or a database migration.
- [ ] **MAINT-OPT-050**: The `security_hardening` optimization type's repair
      standing shall be `manual_only`, and the system shall report its
      findings for manual selection only.
- [ ] **MAINT-OPT-051**: A newly staged optimization type's initial repair
      standing shall be `default_deny`, and shall change only through a
      separate owner authorization recorded against the optimization recipe
      catalog.
- [ ] **MAINT-OPT-052**: The system shall not dispatch an automatic repair
      for a finding whose optimization type's repair standing is
      `manual_only` or `default_deny`, regardless of that finding's assessed
      standing.
- [ ] **MAINT-OPT-053**: The `test_coverage_quality` optimization type shall
      reconcile with RDR-075's planned test-quality recipe, and shall not
      define a second, divergent test-quality investigation.
