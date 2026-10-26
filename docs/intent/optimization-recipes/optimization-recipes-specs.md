# EARS: Maintenance Optimization Recipes

> **Draft — pending owner acceptance.** These `[ ]` claims trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md) and are
> documentation-only preparation for [#4636](https://github.com/viamin/paid/issues/4636).
> They do not enable maintenance or automatic repair.

## Catalog and Start Surface — #4493

- [ ] **MAINT-OPT-001**: The system shall provide catalog entries for Code
      Duplication, Maintainability / Readability, Performance, Security
      Hardening, Cost / Resource Efficiency, Design / Architecture, and Test
      Coverage & Quality.
- [ ] **MAINT-OPT-002**: Each catalog entry shall define its display text,
      investigation instructions, applicable evidence collectors, validation
      guidance, metric hints, and repair standing.
- [ ] **MAINT-OPT-003**: When an authorized user starts an optimization run,
      the UI, API, and MCP shall offer the same catalog selection with the
      same project-scoped authorization.
- [ ] **MAINT-OPT-004**: When a supplied catalog type is unmapped, the system
      shall use the custom-objective maintenance path rather than reject the
      start request.
- [ ] **MAINT-OPT-005**: When a catalog type is selected, the system shall
      persist that selection in the immutable maintenance-run snapshot and
      retain it across retries.
- [ ] **MAINT-OPT-006**: The system shall accept paths, symbols, or a
      free-text natural-language target as optimization scope, subject to the
      base maintenance objective-admission rule.
- [ ] **MAINT-OPT-007**: When scope is supplied, the system shall bound
      recommendations to it while permitting inspection of supporting callers,
      tests, framework entry points, and design documents.
- [ ] **MAINT-OPT-008**: When a recommendation needs changes outside stated
      scope, the system shall explain the expansion and shall require the
      existing explicit authorization before repair scope expands.

## First Recipes and Honest Evidence — #4494

- [ ] **MAINT-OPT-020**: The system shall provide Code Duplication,
      Maintainability / Readability, and Performance as the first executable
      optimization recipes.
- [ ] **MAINT-OPT-021**: When an applicable evidence collector attaches, the
      system shall record its name, version, configuration, and limits on the
      report and affected finding occurrences.
- [ ] **MAINT-OPT-022**: When no applicable collector attaches, the system
      shall report prompt-only investigation coverage rather than tool coverage.
- [ ] **MAINT-OPT-023**: The system shall not recommend consolidation or
      deletion from structural similarity, absent static references, or absent
      test coverage alone.
- [ ] **MAINT-OPT-024**: The system shall preserve counterevidence and
      coverage limitations with each optimization finding.
- [ ] **MAINT-OPT-025**: When a planned evidence check fails or is unavailable,
      the system shall use the base partial-report outcome and shall not claim
      complete coverage.

## Semantic Assessment — #4494 and #4495

- [ ] **MAINT-OPT-040**: The system shall obtain semantic eligibility
      assessment through `agent_harness` using a versioned structured rubric
      with cited evidence.
- [ ] **MAINT-OPT-041**: An eligibility assessment shall contain exactly one
      standing of `supported`, `marginal`, `unsupported`, or `unknown`, an
      explanation, and evidence references.
- [ ] **MAINT-OPT-042**: The system shall treat assessment standings as
      qualitative rubric outcomes, not calibrated numerical probabilities, and
      shall not aggregate them numerically.
- [ ] **MAINT-OPT-043**: The system shall never use raw analyzer-confidence
      values as automatic-repair eligibility input.
- [ ] **MAINT-OPT-044**: When an assessment is missing, malformed, stale, or
      `unknown`, the system shall fail closed for automatic repair while
      retaining the report and finding for manual selection.

## Bounded Auto-Queue — #4495

- [ ] **MAINT-OPT-050**: The system shall keep optimization maintenance runs
      report-only unless an authorized user makes an explicit per-run
      auto-queue election at start; the default shall be off.
- [ ] **MAINT-OPT-051**: The system shall not permit a recurring schedule,
      tenant setting, or recipe default to elect automatic repair.
- [ ] **MAINT-OPT-052**: A per-run election shall record a minimum eligibility
      standing and explicit cost and time caps for every auto-queued repair;
      its default minimum standing shall be `supported`.
- [ ] **MAINT-OPT-053**: The system shall evaluate an auto-queue election only
      after a `completed` report and shall record why it queues nothing after a
      `partial`, `cancelled`, or `budget_exhausted` report.
- [ ] **MAINT-OPT-054**: When a finding meets the elected standing and all
      deterministic gates pass, the system shall create repair work only
      through the existing authorized M04 pathway with source-report and
      finding provenance.
- [ ] **MAINT-OPT-055**: The system shall enforce the elected cost and time
      caps per auto-queued repair and preserve evidence when a cap is exhausted.
- [ ] **MAINT-OPT-056**: When the repair checkout differs from the report
      revision, the system shall revalidate the finding before applying its
      recommendation and visibly retain a failed or unavailable revalidation.
- [ ] **MAINT-OPT-057**: The system shall not create duplicate automatic repair
      work for repeated occurrences of the same canonical finding identity.
- [ ] **MAINT-OPT-058**: The system shall require explicit human authorization
      before a repair exceeds the approved finding's scope.
- [ ] **MAINT-OPT-059**: The system shall allow a per-run election only to
      narrow a catalog repair standing, never to widen it.

## Staged Types and Category Boundaries — #4496

- [ ] **MAINT-OPT-060**: The system shall classify Security Hardening as
      `manual_only` and shall exclude it from automatic repair until a
      separately accepted accuracy and safety policy changes that standing.
- [ ] **MAINT-OPT-061**: The system shall classify Cost / Resource Efficiency,
      Design / Architecture, and Test Coverage & Quality as `default_deny` for
      automatic repair until separate owner authorization with evaluation
      evidence changes their standings.
- [ ] **MAINT-OPT-062**: The system shall permit findings in `manual_only` and
      `default_deny` categories to remain reportable and manually selectable.
- [ ] **MAINT-OPT-063**: When designing Test Coverage & Quality, the system
      shall reconcile it with RDR-075's future test-quality recipe rather than
      create a duplicate maintenance contract.
