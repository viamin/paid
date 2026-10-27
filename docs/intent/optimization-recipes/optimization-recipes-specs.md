# EARS: Optimization Recipes

> **Draft — pending owner acceptance in [#4636](https://github.com/viamin/paid/issues/4636).**
> These are active gaps, not runtime authorization. They trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md) and extend,
> rather than replace, the `MAINT` maintenance contracts.

## Catalog and Selection — #4493

- [ ] **MAINT-OPT-001**: The system shall define the optimization catalog as
      code-defined entries rather than a maintenance-run enum.
- [ ] **MAINT-OPT-002**: The system shall provide entries for Performance,
      Design / Architecture, Code Duplication, Security Hardening, Cost /
      Resource Efficiency, Maintainability / Readability, and Test Coverage &
      Quality.
- [ ] **MAINT-OPT-003**: Each catalog entry shall provide a stable key, display
      name, investigation description, metric hints, and optional recipe
      definition reference.
- [ ] **MAINT-OPT-004**: The system shall present the same optimization catalog
      selection contract through UI, API, and MCP maintenance-run admission.
- [ ] **MAINT-OPT-005**: When no catalog type is selected, the system shall
      admit a valid free-text maintenance objective under `MAINT-011`.
- [ ] **MAINT-OPT-006**: When a submitted type does not resolve to a catalog
      entry, the system shall retain it as a custom-objective maintenance run
      rather than reject admission.
- [ ] **MAINT-OPT-007**: The system shall snapshot a selected catalog key and
      resolved recipe version with the maintenance objective, scope, guidance,
      and limits at run start and retain that snapshot across retries.
- [ ] **MAINT-OPT-008**: The system shall accept files, symbols, features,
      pages, and free-text boundaries as optimization scope without silently
      broadening a named scope.
- [ ] **MAINT-OPT-009**: When supporting inspection reads beyond an optimization
      scope, the report shall disclose that inspection and any coverage limit;
      recommendations and repairs shall remain within the authorized scope.

## First Recipes and Honest Evidence — #4494

- [ ] **MAINT-OPT-010**: The system shall define Code Duplication,
      Maintainability / Readability, and Performance as the first optimization
      recipes.
- [ ] **MAINT-OPT-011**: Each optimization recipe shall define its objective,
      investigation instructions, applicable evidence collectors, validation
      guidance, and metric hints.
- [ ] **MAINT-OPT-012**: When an admitted analyzer contributes to a finding,
      the report shall retain its name, version, configuration, and evidence.
- [ ] **MAINT-OPT-013**: The system shall treat analyzer output and raw tool
      confidence as evidence rather than proof that a recommendation is valid.
- [ ] **MAINT-OPT-014**: Before a duplication recommendation proposes
      consolidation or deletion, the assessment shall consider deliberate
      independence, framework callbacks, dynamic invocation, and relevant
      counterevidence.
- [ ] **MAINT-OPT-015**: Where no applicable tool is admitted for Performance,
      the system shall perform a prompt-first investigation and disclose its
      prompt-only coverage.
- [ ] **MAINT-OPT-016**: A prompt-first recipe with completed planned work and
      no findings shall retain the base `clean` outcome semantics.
- [ ] **MAINT-OPT-020**: The system shall obtain semantic candidate assessment
      only through `agent_harness` using a versioned structured rubric.
- [ ] **MAINT-OPT-021**: A semantic assessment shall include an ordered
      eligibility standing, explanation, evidence and counterevidence
      citations, and a validation plan.
- [ ] **MAINT-OPT-022**: The system shall not treat a raw analyzer confidence
      score as an automatic-repair eligibility input.
- [ ] **MAINT-OPT-023**: The system shall fail closed for automatic repair when
      a semantic assessment is unknown, malformed, or stale while preserving
      the candidate and reason in the report.
- [ ] **MAINT-OPT-024**: The system shall use deterministic code only for
      assessment-shape validation and authorization, category, revision,
      budget, and idempotency enforcement.
- [ ] **MAINT-OPT-025**: The system shall not represent an ordered eligibility
      standing as a calibrated numerical probability without separately
      approved calibration evidence.

## Bounded Automatic Repair — #4495

- [ ] **MAINT-OPT-030**: The system shall default optimization maintenance runs
      to report-only and shall admit automatic repair only from an authorized,
      explicit per-run election recorded at run start.
- [ ] **MAINT-OPT-031**: The run-start automatic-repair election shall include
      a minimum ordered eligibility standing and explicit cost and time limits
      for every repair it can queue.
- [ ] **MAINT-OPT-032**: The system shall queue an elected repair only after a
      `completed` report when its category permits automatic repair, its
      assessment meets the elected standing, and its canonical finding identity
      has no existing automatic-repair idempotency key.
- [ ] **MAINT-OPT-033**: The system shall create every admitted automatic repair
      through the existing authorized bounded-repair pathway with links to its
      source report, occurrence, canonical finding, election, and assessment.
- [ ] **MAINT-OPT-034**: When the repair target revision changed, the system
      shall revalidate source evidence against the repair checkout before the
      repair applies; a failed revalidation shall be visible and shall not
      silently authorize or drop repair work.
- [ ] **MAINT-OPT-035**: The system shall preserve evidence when an
      automatically queued repair exhausts its cost or time limit and shall not
      cancel active repair runs or delete reports when new auto-queue admission
      is disabled.

## Staged Categories — #4496

- [ ] **MAINT-OPT-040**: The system shall make Security Hardening findings
      reportable and manually repairable only, excluding them from automatic
      repair until a separately authorized accuracy and safety review admits
      that category.
- [ ] **MAINT-OPT-041**: The system shall keep Cost / Resource Efficiency,
      Design / Architecture, and Test Coverage & Quality default-deny for
      automatic repair until separate owner authorization supported by
      evaluation evidence changes their standing.
