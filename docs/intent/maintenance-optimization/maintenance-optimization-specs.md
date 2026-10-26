# EARS: Maintenance Optimization Recipes

> **Draft — pending human design acceptance.** These specs trace to
> [`maintenance-optimization-design.md`](maintenance-optimization-design.md).
> They are reviewable intent for [#4636](https://github.com/viamin/paid/issues/4636),
> which `Tracks` [#4492](https://github.com/viamin/paid/issues/4492); neither
> issue is runtime authorization. All claims are active gaps until the base
> RDR-075 maintenance contracts and this leaf are accepted.

## Catalog and Scope — #4493

- [ ] **OPT-CATALOG-001**: The system shall provide the code-defined
      optimization catalog with Performance, Design / Architecture, Code
      Duplication, Security Hardening, Cost / Resource Efficiency,
      Maintainability / Readability, and Test Coverage & Quality entries; each
      entry shall expose a display name, audit description, default metric
      hints, and an optional recipe reference.
- [ ] **OPT-CATALOG-002**: When an authorized user starts an optimization
      maintenance run through the UI, authenticated API, or MCP surface, the
      system shall expose equivalent catalog selection and start authorization
      on every surface, while permitting the run to start without a type
      selection.
- [ ] **OPT-CATALOG-003**: When an optimization type selection has no mapped
      catalog entry or recipe, the system shall create a custom-objective
      maintenance run rather than rejecting the request.
- [ ] **OPT-CATALOG-004**: When an optimization maintenance run starts, the
      system shall snapshot its selected catalog entry, resolved recipe and
      recipe version with its objective, scope, and guidance, and shall retain
      that snapshot across retries.
- [ ] **OPT-SCOPE-001**: When an optimization recipe inspects supporting
      evidence outside its requested scope, the system shall disclose that
      inspection and any recommendation beyond the requested scope in the
      report; it shall require explicit human authorization before expanding a
      repair beyond its approved finding scope.

## Assessment and Evidence — #4494

- [ ] **OPT-ASSESS-001**: The system shall obtain every optimization finding's
      semantic claim, evidence and counterevidence, proposed action,
      verification disposition, and assessment-confidence value through an
      `agent_harness` structured assessment, not application-level semantic
      heuristics.
- [ ] **OPT-ASSESS-002**: The system shall preserve raw tool confidence,
      collector provenance, and coverage separately from an optimization
      finding's `agent_harness` assessment-confidence value.
- [ ] **OPT-ASSESS-003**: When an optimization recipe has no applicable tool,
      the system shall report the prompt-first evidence path honestly; if a
      planned collector is missing, fails, truncates, or is unavailable, it
      shall preserve the maintenance report's incomplete coverage rather than
      claim a clean completed check.
- [ ] **OPT-RECIPE-001**: The system shall define Code Duplication,
      Maintainability / Readability, and Performance recipe entries with
      objective, investigation instructions, applicable evidence collectors,
      validation guidance, and default metric hints; it shall not recommend
      consolidation or deletion from similarity or absent static references
      alone.

## Bounded Auto-Queue — #4495

- [ ] **OPT-REPAIR-001**: When an authorized user starts an individual
      optimization maintenance run, the system shall offer an auto-queue
      election defaulting to disabled; omission shall retain report-only
      maintenance behavior and no tenant, catalog entry, or recipe shall
      enable auto-queue by default.
- [ ] **OPT-REPAIR-002**: When an authorized user elects auto-queue, the
      system shall snapshot an assessment-confidence threshold and explicit
      per-repair cost and time limits with the run.
- [ ] **OPT-REPAIR-003**: When a terminal optimization report has a finding,
      the system shall queue its bounded repair only through the existing M04
      repair pathway after deterministic checks confirm the snapshotted
      election, start-time authorization, feature guard, eligible category,
      structured assessment threshold, per-repair limits, and finding scope.
- [ ] **OPT-REPAIR-004**: When the repair checkout revision differs from an
      auto-queued finding's source-report revision, the system shall revalidate
      the finding before applying its recommendation; if revalidation fails or
      is unavailable, it shall surface that result and shall not silently
      authorize or discard the repair.
- [ ] **OPT-REPAIR-005**: When a repeated report occurrence has the same
      canonical finding identity and source/report policy as repair work
      already created, the system shall not queue a duplicate repair.
- [ ] **OPT-REPAIR-006**: While the `maintenance_runs` guard disallows new
      maintenance admissions, the system shall not create new auto-queued
      repairs and shall not cancel active repair runs or delete reports solely
      because the guard changed.

## Staged Follow-on Recipes — #4496

- [ ] **OPT-FOLLOWON-001**: The system shall register Security Hardening, Cost
      / Resource Efficiency, Design / Architecture, and Test Coverage &
      Quality only as catalog/recipe entries, with prompt-first evidence
      disclosed honestly where a credible collector is unavailable.
- [ ] **OPT-FOLLOWON-002**: When an optimization finding belongs to Security
      Hardening, the system shall exclude it from auto-queue and provide only
      report delivery and manual repair selection until a dedicated
      accuracy-and-safety policy authorizes otherwise.
- [ ] **OPT-FOLLOWON-003**: When the Test Coverage & Quality recipe is
      implemented, the system shall reconcile its recipe definition with the
      RDR-075 test-quality objective rather than create a duplicate maintenance
      objective or repair pathway.
