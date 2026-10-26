# EARS: Maintenance Optimization Recipes

> **Draft — pending design acceptance.** These specs trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md) and,
> through it, to the draft base maintenance contracts
> ([`maintenance-runs-specs.md`](../maintenance-runs/maintenance-runs-specs.md))
> and draft [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md). All
> specs below are `[ ]` active gaps: correct, current intent with no
> implementation. None are implementable until this LLD/EARS pair and the
> base maintenance design are accepted
> ([#4636](https://github.com/viamin/paid/issues/4636),
> [#4635](https://github.com/viamin/paid/issues/4635)) and the base
> milestones the delivery issues declare are in place. Each spec records
> its delivery issue; umbrella
> [#4492](https://github.com/viamin/paid/issues/4492) tracks only and
> delivers no spec.

## Catalog and Type Selection

- [ ] **MAINT-OPT-001**: The system shall define the optimization type
      catalog in code, where each entry carries a key, display name,
      description of what the investigation looks for, default metric
      hints, and a pointer to its recipe definition when one exists, and
      adding a type shall require a catalog entry only — no enum value,
      migration, or run-contract change.
      *Delivery:* #4493 (OPT-01)
- [ ] **MAINT-OPT-002**: The system shall present the curated type menu
      wherever maintenance runs are started — run-trigger form and chat —
      through the UI, API, and MCP surfaces with equivalent project-scoped
      start authorization, and shall keep maintenance runs startable
      without a type selection.
      *Delivery:* #4493 (OPT-01)
- [ ] **MAINT-OPT-003**: When a type is selected at run start, the system
      shall record the selected type key on the run snapshot alongside
      objective, scope, and guidance, shall not mutate it after the run
      starts, and shall retain it across retries.
      *Delivery:* #4493 (OPT-01)
- [ ] **MAINT-OPT-004**: If a submitted type value is not present in the
      catalog, the system shall degrade to a custom-objective maintenance
      run that retains the selection verbatim as context rather than
      raising an error, and the base admission rule — recipe objective or
      nonblank guidance — shall still apply to the degraded run.
      *Delivery:* #4493 (OPT-01)
- [ ] **MAINT-OPT-005**: Where a surface accepts natural-language input,
      the system shall resolve a user description to a catalog type only
      through an `agent_harness` call returning a structured candidate
      type with cited reasons or none, and shall not map descriptions to
      types through keyword, regex, or other code-side text matching.
      *Delivery:* #4493 (OPT-01)
- [ ] **MAINT-OPT-006**: The system shall admit optimization maintenance
      runs only behind the `maintenance_runs` guard with the same
      admission, dispatch, and rollback behavior as base maintenance runs
      (MAINT-001–MAINT-004), with no separate feature flag for the
      optimization family.
      *Delivery:* #4493 (OPT-01)

## Recipes and Honest Evidence

- [ ] **MAINT-OPT-010**: The system shall register the first three
      optimization recipes — code duplication, maintainability/readability,
      and performance — as recipe definitions supplying objective,
      investigation instructions, applicable evidence collectors,
      validation guidance, and default metric hints from their catalog
      entries.
      *Delivery:* #4494 (OPT-02)
- [ ] **MAINT-OPT-011**: The system shall treat analyzer and tool output
      in optimization recipes as candidate evidence only: a finding's
      verification disposition shall be settled by a semantic assessment
      through `agent_harness` against the finding's cited supporting
      evidence and counterevidence (MAINT-025), never derived from
      analyzer output alone.
      *Delivery:* #4494 (OPT-02)
- [ ] **MAINT-OPT-012**: The system shall not recommend consolidation or
      deletion of deliberately independent workflows, or of dynamically
      invoked framework code (callbacks, reflection, external APIs,
      compatibility obligations), solely from analyzer output.
      *Delivery:* #4494 (OPT-02)
- [ ] **MAINT-OPT-013**: Where no tool attaches for an optimization
      recipe — the performance recipe's initial prompt-first path — the
      system shall record prompt-only evidence honestly: no tool check is
      planned for that run, so a completed investigation with no findings
      reports `clean` (MAINT-044), while a planned tool check that fails
      still forces `partial` (MAINT-022).
      *Delivery:* #4494 (OPT-02)
- [ ] **MAINT-OPT-014**: The system shall record resolved analyzer
      name/version/configuration provenance on every optimization finding
      and report that used one (MAINT-043).
      *Delivery:* #4494 (OPT-02)
- [ ] **MAINT-OPT-015**: The system shall accept a free-form
      natural-language scope of any breadth for an optimization run —
      files, a feature, or a page in the app are all valid — composed with
      the selected type without imposing scope limits by default, while
      named scope targets still resolve before coverage is claimed
      (MAINT-012) and ambiguous or missing targets still produce an
      actionable clarification outcome (MAINT-013).
      *Delivery:* #4494 (OPT-02)
- [ ] **MAINT-OPT-016**: The system shall bound optimization
      recommendations, not evidence access, to the requested scope:
      callers, tests, and framework entry points may be inspected outside
      the requested scope for verification, and any recommendation
      requiring changes beyond the requested scope shall identify that
      expansion explicitly and shall not act on it without separate
      authorization.
      *Delivery:* #4494 (OPT-02)
- [ ] **MAINT-OPT-017**: When a repeated optimization scan reproduces a
      finding with the same identity, the system shall update the
      canonical finding and its report-specific occurrences per the base
      recurring-identity contract (MAINT-026, MAINT-027) and shall not
      create duplicate repair work.
      *Delivery:* #4494 (OPT-02)

## Staged Follow-On Types

- [ ] **MAINT-OPT-020**: The system shall register the staged follow-on
      optimization types — security hardening, cost/resource efficiency,
      design/architecture, and test coverage & quality — through the same
      catalog contract as the first recipes, with no enum or migration
      work.
      *Delivery:* #4496 (OPT-04)
- [ ] **MAINT-OPT-021**: The system shall land each staged follow-on type
      only when its predecessors' evaluation evidence supports it, and
      shall record per-stage evaluation evidence on at least one non-Paid
      project.
      *Delivery:* #4496 (OPT-04)
- [ ] **MAINT-OPT-022**: The system shall keep security-category findings
      manual-selection-only for repair: the auto-queue selection gate
      shall exclude security-category findings by default, and shall not
      include them until a dedicated accuracy and blast-radius review
      lands a separately accepted policy authorizing them.
      *Delivery:* #4496 (OPT-04; gate shared with #4495)
- [ ] **MAINT-OPT-023**: The system shall represent test coverage &
      quality as one recipe reconciled with the base maintenance
      capability's anticipated test-quality recipe, and shall not maintain
      a duplicate optimization-specific test-quality recipe.
      *Delivery:* #4496 (OPT-04)
- [ ] **MAINT-OPT-024**: Where a staged follow-on type has no credible
      tool-evidence path, the system shall land it prompt-first and record
      that honestly in its reports.
      *Delivery:* #4496 (OPT-04)

## Bounded Auto-Queue

- [ ] **MAINT-OPT-030**: The system shall offer the auto-queue election
      only per run at start — through the run-trigger form, API, and MCP
      with equivalent authorization — and shall never enable it
      tenant-wide, as a recipe or schedule default, or by election after a
      run has started; an omitted election shall behave exactly as a
      report-only base maintenance run.
      *Delivery:* #4495 (OPT-03)
- [ ] **MAINT-OPT-031**: When a user elects auto-queue at start, the
      system shall record the election immutably in the run snapshot,
      including the chosen confidence threshold and explicit per-repair
      cost/time budget caps, with configured defaults surfaced at election
      time.
      *Delivery:* #4495 (OPT-03)
- [ ] **MAINT-OPT-032**: When an optimization report completes with an
      auto-queue election in effect, the system shall queue a bounded
      repair run only for findings that pass every deterministic gate:
      admission rechecked at dispatch time, auto-queue category
      eligibility, selection confidence meeting or exceeding the elected
      threshold, canonical-finding idempotency, and present budget caps.
      *Delivery:* #4495 (OPT-03)
- [ ] **MAINT-OPT-033**: The system shall derive a finding's selection
      confidence solely from an `agent_harness` semantic assessment
      against a versioned rubric citing the finding occurrence's
      supporting evidence and counterevidence, returning a bounded value
      with explanation and source references; the system shall not
      compute, adjust, or aggregate that value in code, and shall not feed
      raw analyzer or tool confidence scores into the selection gate.
      *Delivery:* #4495 (OPT-03)
- [ ] **MAINT-OPT-034**: If a finding's selection-confidence assessment is
      unknown, unavailable, malformed, or stale at dispatch, the system
      shall not queue that finding, shall keep it visible and manually
      selectable, and shall surface the assessment failure visibly in the
      report rather than silently dropping it.
      *Delivery:* #4495 (OPT-03)
- [ ] **MAINT-OPT-035**: The system shall treat elected confidence
      thresholds as provisional policy settings on a rubric-defined
      evidence-strength scale, not as calibrated probabilities, and shall
      not present auto-queued findings as statistically certain.
      *Delivery:* #4495 (OPT-03)
- [ ] **MAINT-OPT-036**: The system shall always deliver the optimization
      report in full regardless of any election: auto-queue selection
      shall affect only repair dispatch, and findings below the elected
      threshold or excluded by category shall remain visible and manually
      selectable (MAINT-018, MAINT-070).
      *Delivery:* #4495 (OPT-03)
- [ ] **MAINT-OPT-037**: The system shall dispatch auto-queued repairs
      only through the base repair-handoff pathways unchanged, including
      provenance links to the source report and finding identity
      (MAINT-072) and revalidation when the target revision has moved
      (MAINT-071), and shall surface dispatch or revalidation failures
      visibly on the queued work rather than silently dropping them.
      *Delivery:* #4495 (OPT-03)
- [ ] **MAINT-OPT-038**: The system shall bound each auto-queued repair
      run's scope to its selected finding and shall enforce its elected
      budget caps, preserving collected evidence on exhaustion per the
      base budget contract (MAINT-024).
      *Delivery:* #4495 (OPT-03)
- [ ] **MAINT-OPT-039**: While repair work for a canonical finding
      identity is already queued, active, or completed, the system shall
      not queue duplicate repair work for that finding (MAINT-026,
      MAINT-027).
      *Delivery:* #4495 (OPT-03)
- [ ] **MAINT-OPT-040**: When the `maintenance_runs` guard is disabled or
      rolled back, the system shall stop new auto-queue dispatch without
      cancelling already-active repair runs or deleting reports
      (MAINT-003, MAINT-004).
      *Delivery:* #4495 (OPT-03)
- [ ] **MAINT-OPT-041**: The system shall not allow a maintenance schedule
      to auto-queue repairs unless and until a separately accepted design
      extends the election to schedules; until then, schedule-dispatched
      optimization runs shall be report-only.
      *Delivery:* #4495 (OPT-03)
