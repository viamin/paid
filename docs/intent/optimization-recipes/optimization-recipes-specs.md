# EARS: Optimization Recipes and Bounded Repair Policy

> **Draft — pending owner acceptance (#4636).** All claims are active gaps;
> none authorizes implementation, runtime admission, or rollout. #4492 is
> tracking-only; delivery tags identify the executable child issue.

## Catalog and Scope — #4493

- [ ] **MAINT-OPT-001**: The system shall provide the seven initial
      optimization catalog types as code-defined entries with display name,
      description, metric hints, recipe reference, and repair standing.
- [ ] **MAINT-OPT-002**: The system shall add a catalog type without a run
      contract enum migration or project-admin authoring UI.
- [ ] **MAINT-OPT-003**: The system shall present the optional catalog menu
      with equivalent authorization and behavior in UI, API, and MCP starts.
- [ ] **MAINT-OPT-004**: When a selected catalog type has no mapped recipe,
      the system shall start a custom-objective maintenance run rather than
      reject the request.
- [ ] **MAINT-OPT-005**: The system shall snapshot selected type, objective,
      scope, guidance, and recipe version at run start and retain them on retry.
- [ ] **MAINT-OPT-006**: When scope names a file, symbol, feature, or page, the
      system shall bound recommendations to that scope while allowing and
      disclosing supporting inspection outside it.

## Recipes and Evidence — #4494

- [ ] **MAINT-OPT-010**: The system shall register Code Duplication,
      Maintainability / Readability, and Performance recipes with objective,
      instructions, collectors, validation guidance, and metric hints.
- [ ] **MAINT-OPT-011**: The system shall record tool name, version, and
      configuration provenance whenever a recipe uses tool evidence.
- [ ] **MAINT-OPT-012**: The system shall record prompt-only evidence and
      coverage honestly when a prompt-first recipe has no planned tool check.
- [ ] **MAINT-OPT-013**: The system shall not recommend consolidation or
      deletion from similarity or analyzer output alone without assessment of
      independence, framework invocation, and counterevidence.
- [ ] **MAINT-OPT-014**: The system shall retain a clean outcome only under the
      base complete-coverage contract and shall expose every failed planned
      check as partial coverage.
- [ ] **MAINT-OPT-015**: The system shall retain canonical finding identity and
      immutable report occurrences for repeated optimization scans.

## Semantic Assessment — #4494 and #4495

- [ ] **MAINT-OPT-020**: The system shall request semantic finding assessment
      only through `agent_harness` using a versioned structured rubric.
- [ ] **MAINT-OPT-021**: The assessment shall include recommendation, bounded
      rationale, citations, counterevidence, validation plan, and standing.
- [ ] **MAINT-OPT-022**: The system shall treat raw analyzer confidence as
      evidence only and shall not use it as an automatic-repair gate.
- [ ] **MAINT-OPT-023**: The system shall accept only `supported`, `marginal`,
      or `unsupported` as an assessment standing; malformed, unknown, or stale
      assessments shall fail closed.
- [ ] **MAINT-OPT-024**: The system shall apply a configured minimum standing
      per run and finding without treating it as a calibrated numeric probability.

## Bounded Automatic Repair — #4495

- [ ] **MAINT-OPT-030**: The system shall keep automatic repair off unless an
      authorized user explicitly elects it at run start through equivalent UI,
      API, and MCP behavior.
- [ ] **MAINT-OPT-031**: The system shall default the minimum standing for an
      elected automatic repair to `supported`.
- [ ] **MAINT-OPT-032**: The system shall deliver the full report regardless of
      whether any finding qualifies for automatic repair.
- [ ] **MAINT-OPT-033**: The system shall queue an elected automatic repair
      only from a `completed` report, never a partial, cancelled, or
      budget-exhausted report.
- [ ] **MAINT-OPT-034**: Before queueing, the system shall enforce current
      authorization, guard state, category standing, assessment freshness,
      finding-only scope, explicit per-repair cost/time caps, and threshold.
- [ ] **MAINT-OPT-035**: If the repair checkout revision differs from the
      report revision, the system shall revalidate evidence before applying a
      queued recommendation.
- [ ] **MAINT-OPT-036**: The system shall preserve evidence and visibly report
      budget exhaustion, revalidation failure, or another denied gate.
- [ ] **MAINT-OPT-037**: The system shall link each queued repair to source
      report and finding and deduplicate dispatch by canonical finding identity.
- [ ] **MAINT-OPT-038**: A run-start election shall only narrow authorization,
      categories, or caps; it shall not elevate a catalog standing or create a
      tenant, schedule, or recipe default.

## Staged Types and Policy — #4496

- [ ] **MAINT-OPT-040**: The system shall register Security Hardening, Cost /
      Resource Efficiency, Design / Architecture, and Test Coverage & Quality
      only through the catalog contract.
- [ ] **MAINT-OPT-041**: The system shall classify Security Hardening as
      `manual_only` and shall exclude it from automatic repair until separately
      authorized by an accuracy and safety review.
- [ ] **MAINT-OPT-042**: The system shall classify Cost / Resource Efficiency,
      Design / Architecture, and Test Coverage & Quality as `default_deny`
      until separate owner authorization backed by evaluation evidence.
- [ ] **MAINT-OPT-043**: The system shall reconcile Test Coverage & Quality
      with RDR-075's test-quality recipe rather than duplicate it.
- [ ] **MAINT-OPT-044**: The system shall keep all staged recipes behind the
      existing default-off `maintenance_runs` guard.
