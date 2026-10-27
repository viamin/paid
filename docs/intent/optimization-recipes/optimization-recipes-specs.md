# EARS: Optimization Recipe Family

> **Draft — pending design acceptance.** These specs trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md), which
> is itself pending acceptance via
> [#4636](https://github.com/viamin/paid/issues/4636) and consumes the
> still-unaccepted base [`maintenance-runs`](../maintenance-runs/maintenance-runs-specs.md)
> contract. All specs below are `[ ]` active gaps: correct, current intent
> with no implementation yet. None are implementable until the base
> maintenance LLD/EARS (#4635) and this LLD/EARS (#4636) are both accepted
> and merged. Each section cites its owning delivery issue; #4492 is a
> tracking umbrella and owns no specs.

## Catalog and Type Menu (owned by #4493)

- [ ] **MAINT-OPT-001**: The system shall define the optimization recipe
      catalog as code-defined entries, never a hard enum in the maintenance
      run contract; adding a type shall require a catalog entry only, no
      migration.
- [ ] **MAINT-OPT-002**: The system shall register seven initial catalog
      entries — Performance, Design/Architecture, Code Duplication, Security
      Hardening, Cost/Resource Efficiency, Maintainability/Readability, and
      Test Coverage & Quality — each with a display name, a description of
      what the recipe looks for, default metric hints, and a pointer to its
      recipe definition when one exists.
- [ ] **MAINT-OPT-003**: The system shall surface the optimization type menu
      with equivalent behavior in the project UI and the API/MCP surfaces
      wherever a maintenance run can be started, composing with the base
      maintenance scope field rather than replacing it.
- [ ] **MAINT-OPT-004**: The system shall allow a maintenance run to start
      without selecting an optimization type, per the base maintenance
      objective-or-guidance admission rule.
- [ ] **MAINT-OPT-005**: If a selected or submitted catalog type value does
      not resolve to a known catalog entry, then the system shall degrade
      to a custom-objective maintenance run rather than failing the start
      request.
- [ ] **MAINT-OPT-006**: The system shall persist the selected optimization
      catalog type on the run snapshot alongside objective/scope/guidance
      (base maintenance `MAINT-015`) and retain it across retries.
- [ ] **MAINT-OPT-007**: The system shall accept paths, symbols, or a
      free-form natural-language target (a feature, a workflow, a page in
      the app) as scope for an optimization maintenance run, consistent with
      the reconciled base maintenance scope contract (`MAINT-011`).

## First Recipes and Honest Evidence (owned by #4494)

- [ ] **MAINT-OPT-010**: The system shall register three initial optimization
      recipes — Code Duplication (tool-assisted), Maintainability/Readability
      (tool-assisted where a complexity analyzer attaches, agent-assessed
      otherwise), and Performance (prompt-first, no blocking analyzer
      dependency) — each with a catalog entry.
- [ ] **MAINT-OPT-011**: The system shall supply, for every registered
      optimization recipe, its objective, investigation instructions,
      applicable evidence collectors, validation guidance, and default
      metric hints.
- [ ] **MAINT-OPT-012**: The system shall record analyzer name/version/
      configuration provenance (base maintenance `MAINT-043`) on every
      finding produced by a tool-assisted optimization recipe, and shall
      record honestly, on a prompt-first finding, that no tool attached.
- [ ] **MAINT-OPT-013**: If a Code Duplication finding's sole supporting
      evidence is analyzer-reported similarity, then the system shall not
      propose consolidation or deletion as the finding's action without
      considering deliberate independence and framework-callback or
      dynamic-invocation context first (RDR-075 validation scenario 3).
- [ ] **MAINT-OPT-014**: The system shall treat an optimization recipe's
      scope as bounding its recommendations, not its supporting-evidence
      access — callers, tests, and framework entry points outside the
      requested scope may be inspected to validate a claim, consistent with
      base RDR-075's scope-vs-evidence distinction.
- [ ] **MAINT-OPT-015**: The system shall report an optimization scan whose
      planned checks all completed with no qualifying findings as `clean`
      (base maintenance `MAINT-020`/`MAINT-044`), never as a failure or as
      `partial`.
- [ ] **MAINT-OPT-016**: When a repeated optimization scan reproduces a
      finding with the same canonical identity (base maintenance
      `MAINT-026`), the system shall create a new occurrence on the existing
      canonical finding rather than a duplicate finding or repair candidate.

## Semantic Assessment and Deterministic Gates (owned by #4495)

- [ ] **MAINT-OPT-020**: The system shall obtain whether an optimization
      finding meets the auto-queue selection policy from an `agent_harness`
      semantic-assessment call against a versioned rubric, and shall not
      compute that determination from a regex, keyword match, or raw
      tool-reported metric in application code.
- [ ] **MAINT-OPT-021**: The system shall require the semantic-assessment
      call to return a bounded, ordered standing from a fixed small
      vocabulary plus an explanation and evidence citations, and shall not
      accept or construct a free-floating numeric confidence score as a
      substitute for that standing.
- [ ] **MAINT-OPT-022**: The system shall express the auto-queue selection
      policy as a deterministic, project-configurable threshold over the
      assessment's bounded standing, compared in code; the semantic-
      assessment call shall supply the standing only, never the threshold
      comparison itself.
- [ ] **MAINT-OPT-023**: If a finding's semantic assessment is missing,
      malformed, or does not resolve to a known standing value, then the
      system shall exclude that finding from auto-queue selection and shall
      not default it to a qualifying standing.
- [ ] **MAINT-OPT-024**: The system shall enforce per-run opt-in
      authorization, category exclusion, per-repair budget, and canonical-
      finding idempotency for auto-queue dispatch as deterministic checks
      independent of the semantic assessment; an eligible standing shall be
      necessary but not sufficient for dispatch.

## Bounded Automatic Repair / Auto-Queue Policy (owned by #4495)

- [ ] **MAINT-OPT-030**: The system shall offer the auto-queue option only
      as a per-run election captured at run start, through the trigger form
      and API/MCP with equivalent authorization, and shall never apply it as
      a tenant-wide or recipe-wide default; a run that omits the election
      shall behave identically to a report-only run.
- [ ] **MAINT-OPT-031**: The system shall not allow a `MaintenanceSchedule`
      to carry a standing auto-queue election; each scheduled occurrence is
      a fresh run and the schedule's stored configuration shall not include
      an auto-queue election field.
- [ ] **MAINT-OPT-032**: The system shall persist the run-start auto-queue
      election's selection-standing threshold and per-repair budget caps on
      the run snapshot, immutably once the run starts, consistent with base
      maintenance `MAINT-015`.
- [ ] **MAINT-OPT-033**: When a maintenance run with an active auto-queue
      election produces a `completed` report, the system shall dispatch a
      bounded repair run through the existing repair-handoff pathway
      (`MAINT-070`) for every open finding whose semantic assessment meets
      the elected threshold, and shall leave every below-threshold finding
      available for manual selection in the full report.
- [ ] **MAINT-OPT-034**: If a maintenance run's report outcome is `partial`,
      `cancelled`, or `budget_exhausted`, then the system shall not dispatch
      any auto-queued repair run from that report, regardless of an active
      auto-queue election.
- [ ] **MAINT-OPT-035**: The system shall assign every auto-queued repair run
      its own explicit cost/time budget caps, distinct from the originating
      maintenance run's budget, and shall preserve collected repair evidence
      on exhaustion (base maintenance `MAINT-024`) rather than discarding it.
- [ ] **MAINT-OPT-036**: The system shall apply the same revalidation
      requirement to an auto-queued repair run as to a manually selected one
      (base maintenance `MAINT-071`); if the target revision has moved,
      revalidation shall run before the recommendation applies, and a
      revalidation failure shall surface visibly rather than silently
      dropping the repair.
- [ ] **MAINT-OPT-037**: The system shall bound an auto-queued repair run's
      scope to its originating finding; broadening beyond that finding shall
      require the same explicit human authorization a manually selected
      repair requires.
- [ ] **MAINT-OPT-038**: If a canonical finding already has an open or
      completed repair linked to it, then the system shall exclude that
      finding from a later auto-queue dispatch rather than queuing a
      duplicate repair run.
- [ ] **MAINT-OPT-039**: The system shall link every auto-queued repair run
      back to its source report and canonical finding identically to a
      manually selected repair (base maintenance `MAINT-072`).

## Security Exclusion and Staged Follow-on Types (owned by #4496)

- [ ] **MAINT-OPT-040**: The system shall exclude every Security Hardening
      finding from auto-queue dispatch unconditionally, regardless of its
      assessed standing, until a dedicated accuracy/blast-radius policy
      review separately authorizes a security auto-queue path.
- [ ] **MAINT-OPT-041**: When a staged catalog type (Cost/Resource
      Efficiency, Design/Architecture, or Test Coverage & Quality) is first
      registered in the catalog, the system shall default that type to
      `default_deny` for auto-queue eligibility and shall not inherit
      threshold-eligibility from the already-accepted auto-queue policy for
      other types.
- [ ] **MAINT-OPT-042**: The system shall reconcile the Test Coverage &
      Quality catalog type's recipe content with RDR-075's own referenced
      future test-quality recipe rather than registering a second,
      overlapping recipe for the same objective.
