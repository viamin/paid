# EARS: Optimization Recipes and Bounded Repair Policy

> **Draft — pending owner acceptance through #4636.** These specs trace to
> [optimization-recipes-design.md](optimization-recipes-design.md) and refine
> the draft MAINT contract. They are documentation-only preparation for
> #4493–#4496, do not authorize implementation or rollout, and remain inactive
> until the independent RDR-075 acceptance and implementation prerequisites
> are satisfied.

## Catalog and Selection — #4493

- [ ] **OPT-001**: The system shall provide versioned catalog entries for the
      optimization types performance, design/architecture, code duplication,
      security hardening, cost/resource efficiency,
      maintainability/readability, and test coverage/quality; each entry shall
      define a stable key, display metadata, objective, instructions,
      applicable evidence collectors, validation guidance, and metric hints.
- [ ] **OPT-002**: The system shall admit an optimization type selected through
      the UI, authenticated API, or MCP surface under the same authorization
      and `maintenance_runs` guard as MAINT-010–MAINT-011, and shall snapshot
      the selected entry and version with the maintenance run.
- [ ] **OPT-003**: Where no catalog type is selected, the system shall retain
      the MAINT-011 free-text maintenance objective path; where an unmapped
      type value is submitted, it shall create a custom-objective run rather
      than reject the request.
- [ ] **OPT-004**: The system shall add an optimization type by catalog entry
      and recipe content without requiring an enum migration or a new
      maintenance run type.

## Recipe Evidence and Scope — #4494 and #4496

- [ ] **OPT-010**: The system shall define code-duplication,
      maintainability/readability, and performance recipes with objective,
      instructions, applicable evidence collectors, validation guidance, and
      metric hints, and shall retain collector version/configuration provenance
      under MAINT-043 when a collector is used.
- [ ] **OPT-011**: Where a selected optimization recipe has no credible
      applicable evidence collector, the system shall perform a prompt-first
      investigation under MAINT-044 and shall disclose that limitation in its
      report.
- [ ] **OPT-012**: The system shall assess duplication candidates against
      counterevidence including intentional independence, callers, tests,
      framework entry points, and compatibility obligations before presenting a
      sharing recommendation.
- [ ] **OPT-013**: The system shall preserve MAINT's report coverage outcomes
      for optimization recipes and shall never present missing, failed, or
      truncated collection as a clean result.
- [ ] **OPT-014**: The system shall treat requested optimization scope as a
      bound on recommendations, not on supporting inspection, and shall
      disclose supporting inspection beyond that scope and any coverage limits.
- [ ] **OPT-015**: The system shall define staged security hardening,
      cost/resource efficiency, design/architecture, and test coverage/quality
      recipes as catalog entries with the same evidence and reporting contract
      as OPT-010–OPT-014.
- [ ] **OPT-016**: The system shall keep security-hardening findings
      report-only and available for explicit manual repair selection until a
      separately accepted security-repair policy authorizes any automatic
      repair.
- [ ] **OPT-017**: The system shall disclose prompt-first evidence limitations
      for cost/resource-efficiency and design/architecture recipes where no
      credible applicable collector exists.
- [ ] **OPT-018**: The system shall reconcile the test coverage/quality recipe
      with RDR-075's planned test-quality maintenance recipe and shall not
      create a duplicate maintenance lifecycle or reporting contract.
- [ ] **OPT-019**: The system shall preserve each optimization finding's
      canonical identity and immutable report-specific occurrence under
      MAINT-026–MAINT-029 when a recipe is repeated.

## Semantic Assessment and Bounded Auto-Queue — #4495

- [ ] **OPT-020**: The system shall obtain an optimization finding's semantic
      assessment through `agent_harness` as a structured result containing its
      claim, supporting evidence, counterevidence, coverage limitations,
      verification disposition, and satisfaction or non-satisfaction of the
      run's snapshotted auto-queue confidence criterion; raw collector scores
      shall remain evidence and shall not independently authorize a repair.
- [ ] **OPT-021**: The system shall allow an authorized user to elect
      auto-queue only when starting an optimization run, default the election
      to off, expose the same election and authorization through UI, API, and
      MCP, and snapshot its confidence criterion and explicit per-repair cost
      and time limits; omission shall preserve MAINT's manual-selection-only
      behavior.
- [ ] **OPT-022**: When a completed optimization report has a non-security
      finding with a structurally valid semantic assessment that satisfies the
      snapshotted criterion, then the system shall request a bounded repair
      only through the existing authorized MAINT-070 pathway, attach the
      source report, occurrence, and canonical-finding provenance, and apply
      the snapshotted per-repair cost and time limits.
- [ ] **OPT-023**: Before applying an auto-queued repair whose target revision
      has changed, the system shall require MAINT-071 revalidation; if that
      revalidation fails or is unavailable, it shall visibly withhold the
      repair rather than silently applying or dropping it.
- [ ] **OPT-024**: The system shall not auto-queue a security finding, a
      finding without the per-run election, a finding that fails its
      snapshotted criterion, a finding lacking explicit repair limits, or a
      finding whose canonical identity already has queued or created automatic
      repair lineage; it shall preserve evidence on budget exhaustion and
      shall not cancel active repair work or delete reports when the
      `maintenance_runs` guard is disabled.
