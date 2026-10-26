# EARS: Optimization Recipe Family and Bounded Automatic Repair

> **Draft — pending owner acceptance.** These specs trace to
> [`maintenance-optimization-design.md`](maintenance-optimization-design.md),
> itself a reviewable draft against the RDR-075 design and the base
> [`maintenance-runs`](../maintenance-runs/maintenance-runs-specs.md)
> contracts. All specs below are `[ ]` active gaps: correct, current intent
> with no implementation yet. None are implementable until this LLD/EARS pair
> is accepted and the base maintenance acceptance
> ([#4635](https://github.com/viamin/paid/issues/4635)) is recorded. The
> executable deliverables are [#4493](https://github.com/viamin/paid/issues/4493)–[#4496](https://github.com/viamin/paid/issues/4496);
> [#4492](https://github.com/viamin/paid/issues/4492) is their tracking
> umbrella, not an implementation prerequisite.

## Admission and Rollout Guard

- [ ] **MAINT-OPT-001**: Where the `maintenance_runs` guard is disabled for a
      project's tenant, the system shall refuse to admit an optimization
      maintenance run from the UI, API, and MCP surfaces identically, and shall
      queue no automatic-repair work for any run of that tenant.
- [ ] **MAINT-OPT-002**: While a `maintenance_runs` rollback is in effect, the
      system shall keep existing optimization reports readable, shall keep
      already-admitted automatic-repair runs running and cancellable, and
      shall start no new automatic-repair queue.
- [ ] **MAINT-OPT-003**: The system shall run an optimization investigation as
      a maintenance run whose recipe family is `optimization`, and shall not
      introduce a separate run goal for the optimization family.
- [ ] **MAINT-OPT-004**: The system shall not define a second feature flag,
      tenant switch, or project setting for automatic repair; the run-start
      election is the only authorization surface for it.
- [ ] **MAINT-OPT-005**: The system shall admit an optimization maintenance
      run only when the request names a catalog type that resolves to a
      catalog entry, or carries a nonblank objective or free-text guidance; a
      scope selection alone shall not admit an optimization run.
- [ ] **MAINT-OPT-006**: The system shall consume the base maintenance report
      outcomes, canonical finding identity, finding occurrence records, and
      repair handoff rather than defining parallel report, finding, or repair
      models for the optimization family.

## Recipe Catalog and Type Menu

- [ ] **MAINT-OPT-010**: The system shall provide a code-defined optimization
      type catalog whose entries each carry a stable key, a display name, a
      description of what the agent looks for, default metric hints, a
      pointer to a recipe definition when one exists, a delivery stage, and an
      automatic-repair standing.
- [ ] **MAINT-OPT-011**: The system shall seed the optimization catalog with
      the seven curated types — Code Duplication, Maintainability /
      Readability, Performance, Security Hardening, Cost / Resource
      Efficiency, Design / Architecture, and Test Coverage & Quality — each
      registered as a catalog entry only, with the first three marked as the
      first delivery stage and the remaining four as the staged stage.
- [ ] **MAINT-OPT-012**: The system shall add a new optimization type by
      adding a catalog entry, without a schema migration, an enum change, or
      a project-admin authoring surface.
- [ ] **MAINT-OPT-013**: The system shall surface the optimization catalog as
      a type menu wherever a maintenance run is started — UI, authenticated
      API, and MCP — with equivalent authorization and equivalent available
      entries on every surface, and shall admit a maintenance run without a
      type selection.
- [ ] **MAINT-OPT-014**: The system shall persist the selected catalog type
      key on the maintenance run snapshot together with the objective, scope,
      and guidance, and shall retain that selection across retries of the run.
- [ ] **MAINT-OPT-015**: When a submitted type value matches no catalog
      entry, the system shall degrade the request to a custom-objective
      maintenance run and record the unmapped value on the run snapshot rather
      than failing the request; where the degraded request carries no other
      objective or free-text guidance, the system shall refuse to admit it.
- [ ] **MAINT-OPT-016**: When a selected catalog entry has no available
      packaged recipe definition, the system shall conduct a custom-objective
      investigation carrying that entry's key, description, and metric hints,
      and the report shall disclose that no packaged recipe backed the
      investigation; the run shall not claim recipe-backed coverage.
- [ ] **MAINT-OPT-017**: The system shall not treat a catalog type selection
      as a scope restriction, as a blocking gate, or as authorization to
      change source code.

## Recipe Execution and Honest Evidence

- [ ] **MAINT-OPT-020**: A recipe definition shall supply an objective,
      investigation instructions, applicable evidence collectors, validation
      guidance, and default metric hints.
- [ ] **MAINT-OPT-021**: The system shall record the resolved analyzer
      name, version, and configuration as provenance on every finding and
      report that used it, and shall keep that provenance distinct from the
      agent's verification disposition.
- [ ] **MAINT-OPT-022**: Where no applicable tool or native analyzer exists
      for the selected recipe and repository, the system shall complete the
      investigation prompt-only and shall record the prompt-only coverage
      honestly, with no tool check planned for that run.
- [ ] **MAINT-OPT-023**: The system shall attach a recipe's default metric
      hints to its findings as hypotheses, and shall not present a metric hint
      as a measured value or as a calibrated improvement estimate.
- [ ] **MAINT-OPT-024**: For a code-duplication investigation, the system
      shall not recommend consolidation or deletion on similarity alone, and
      the assessment shall consider deliberate independence, framework
      callbacks, reflection, external APIs, and compatibility obligations.
- [ ] **MAINT-OPT-025**: For a performance investigation, the system shall
      investigate algorithmic, hot-path, and I/O behavior within the resolved
      scope, and shall not present an unmeasured hypothesis as a measured
      latency or cost reduction.
- [ ] **MAINT-OPT-026**: Where a planned check did not complete, the system
      shall report the base `partial` outcome and name the checks that did
      not complete, so an optimization report never presents incomplete
      coverage as a clean result.
- [ ] **MAINT-OPT-027**: The system shall record, for every optimization run,
      the packaged recipe version and the catalog-entry version used, so that
      provenance remains comparable across repeated scans of the same project.

## Scope

- [ ] **MAINT-OPT-030**: The system shall accept, for an optimization run, a
      scope expressed as paths, as symbols, or as free-text natural language
      describing an area under investigation such as a file set, a feature,
      or a page.
- [ ] **MAINT-OPT-031**: The system shall resolve the requested scope before
      any check claims coverage of it, and shall perform that resolution
      through `agent_harness` with a structured response.
- [ ] **MAINT-OPT-032**: Where the requested scope is ambiguous or missing,
      the system shall produce an actionable clarification outcome rather than
      silently broadening the investigation.
- [ ] **MAINT-OPT-033**: Where no scope is supplied, the system shall record
      the run as an explicit broad-scope investigation and shall not impose a
      default scope limit on the recommendations it may make.
- [ ] **MAINT-OPT-034**: The scope shall bound the recommendations a run may
      make and not the evidence it may inspect; a recommendation requiring
      changes beyond the resolved scope shall require explicit human
      authorization before any repair is applied.
- [ ] **MAINT-OPT-035**: The system shall record the requested scope, the
      resolved scope, and any exclusions separately on the report.

## Bounded Automatic Repair

- [ ] **MAINT-OPT-040**: The system shall offer an automatic-repair election
      when a maintenance run is started, on the UI, authenticated API, and MCP
      surfaces with equivalent authorization; the election shall be a per-run
      choice, shall never be a tenant-wide or recipe default, and shall be off
      when omitted.
- [ ] **MAINT-OPT-041**: The system shall record on the run snapshot, for an
      enabled election, the minimum assessment standing required for
      automatic repair, the per-repair cost and time caps, and the categories
      the election covers; the recorded categories may narrow the qualifying
      categories but shall never widen a catalog type's automatic-repair
      standing; a run whose election is omitted shall behave exactly as a
      report-only run.
- [ ] **MAINT-OPT-042**: Where a run's election is enabled and its report
      reaches the terminal `completed` outcome, the system shall queue a
      bounded repair run for each finding that satisfies every gate enumerated
      in `MAINT-OPT-053`, shall link each queued repair run back to its source
      report and canonical finding identity, and shall deliver the full report
      whether or not any finding qualifies; a report whose outcome is
      `partial`, `cancelled`, or `budget_exhausted` shall queue no automatic
      repair and shall record that reason on the report.
- [ ] **MAINT-OPT-043**: A finding that does not qualify for automatic repair
      shall remain available for manual selection through the base repair
      pathways, and the system shall record its exclusion with a reason.
- [ ] **MAINT-OPT-044**: Each auto-queued repair run shall carry the
      election's explicit cost and time caps, and where such a repair run
      exhausts its budget the system shall preserve the evidence collected up
      to that point.
- [ ] **MAINT-OPT-045**: Where the repair target's revision has moved since
      the source report was generated, the system shall require revalidation
      of the selected finding's evidence before the repair applies; stale
      evidence shall never authorize a repair.
- [ ] **MAINT-OPT-046**: The system shall not queue a second automatic repair for
      a canonical finding identity that already has a queued or created repair
      run, so that a repeated occurrence of that identity does not create
      duplicate repair work.
- [ ] **MAINT-OPT-047**: The system shall exclude security-hardening findings
      from automatic repair; a security finding shall remain report-only with
      manual selection until a separately authorized accuracy and safety
      review admits it, and a run-start election shall never admit it.
- [ ] **MAINT-OPT-048**: The system shall deny automatic repair for the staged
      recipe types — cost and resource efficiency, design and architecture,
      and test coverage and quality — until a separate owner authorization
      changes their standing, and a run-start election shall never change a
      catalog type's automatic-repair standing.
- [ ] **MAINT-OPT-049**: The system shall record every automatic-repair
      decision — queued, skipped, or failed — on the report with its reason,
      and shall never drop a skipped or failed automatic repair silently.

## Semantic Assessment and Deterministic Gates

- [ ] **MAINT-OPT-050**: The system shall produce every semantic judgment in
      this family — scope resolution, finding verification, repair
      eligibility, and repair-scope correspondence — through an
      `agent_harness` call with a structured response schema, and shall not
      infer meaning from text, keywords, or raw analyzer confidence scores.
- [ ] **MAINT-OPT-051**: The repair-eligibility assessment shall return a
      discrete, ordered standing with an explicit `unknown` value, together
      with evidence references and a rationale, and shall not assert or imply
      a calibrated probability, confidence score, or numeric percentage.
- [ ] **MAINT-OPT-052**: The system shall compare the configured minimum
      standing against the assessed standing using the assessment's own
      discrete labels, and an assessment that is `unknown`, unavailable, or
      malformed shall never satisfy any configured standing.
- [ ] **MAINT-OPT-053**: The system shall apply, in code and before any
      repair is queued, the tenant rollout guard, the presence and validity
      of the run-start election, the finding's automatic-repair standing, the
      initiator's authorization for the repair-creation pathway, the assessed
      standing against the configured minimum, the election's budget caps, the
      canonical-finding idempotency check, and the revision-revalidation
      check.
- [ ] **MAINT-OPT-054**: An auto-queued repair shall be bounded to the
      approved finding, and a repair that requires changes beyond that
      finding's scope shall require explicit human authorization before it
      proceeds.
- [ ] **MAINT-OPT-055**: The system shall not let any semantic assessment
      outcome waive a deterministic gate; no assessment may admit a repair
      that the guard, election, standing, authorization, budget, idempotency,
      or revalidation checks rejected.
- [ ] **MAINT-OPT-056**: The system shall not use a raw analyzer confidence
      score as the input to the automatic-repair selection threshold.
