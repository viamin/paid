# EARS: Optimization Recipes

> **Draft — pending owner acceptance.** All claims are active gaps and none
> authorize runtime behavior. #4492 is tracking only; the headers identify the
> executable delivery issue for each claim.

## Catalog and Menu — #4493

- [ ] **MAINT-OPT-001**: The system shall define the optimization types
      Performance, Design / Architecture, Code Duplication, Security Hardening,
      Cost / Resource Efficiency, Maintainability / Readability, and Test
      Coverage & Quality as code-defined catalog entries.
- [ ] **MAINT-OPT-002**: The system shall record for every catalog entry a
      stable key, display name, description, metric hints, recipe reference
      where present, and repair standing.
- [ ] **MAINT-OPT-003**: The system shall add an optimization type by adding a
      catalog/recipe entry, without a run-contract enum migration or v1
      project-administrator authoring surface.
- [ ] **MAINT-OPT-004**: The system shall present the same optional curated
      type selection in the UI, authenticated API, and MCP maintenance-start
      surfaces, with equivalent project-scoped authorization.
- [ ] **MAINT-OPT-005**: When a user starts a run without selecting an
      optimization type, the system shall preserve ordinary maintenance-run
      admission.
- [ ] **MAINT-OPT-006**: The system shall persist a selected optimization type
      in the immutable maintenance-run snapshot and retain it across retries.
- [ ] **MAINT-OPT-007**: When a supplied type has no catalog mapping, the
      system shall admit it as a custom-objective maintenance run rather than
      rejecting the start request.
- [ ] **MAINT-OPT-008**: The system shall apply the `maintenance_runs` guard
      and rollback behavior to optimization admission exactly as MAINT-001
      through MAINT-004 require.

## First Recipes and Evidence — #4494

- [ ] **MAINT-OPT-010**: The system shall register Code Duplication,
      Maintainability / Readability, and Performance as recipe definitions
      with objective, instructions, applicable collectors, validation guidance,
      and metric hints.
- [ ] **MAINT-OPT-011**: The system shall treat a free-form natural-language
      target, paths, and symbols as valid optimization scope forms.
- [ ] **MAINT-OPT-012**: The system shall bound optimization recommendations
      to the requested scope while permitting supporting inspection of callers,
      tests, entry points, and design documents outside that scope.
- [ ] **MAINT-OPT-013**: The system shall not recommend consolidation or
      deletion from similarity, missing static references, or test coverage
      alone without assessing counterevidence such as deliberate independence,
      framework callbacks, reflection, external contracts, or compatibility.
- [ ] **MAINT-OPT-014**: The system shall record analyzer name, version, and
      configuration on every optimization report and finding that uses tool
      evidence.
- [ ] **MAINT-OPT-015**: When Performance runs without an applicable attached
      tool, the system shall retain prompt-only evidence and report coverage
      honestly rather than represent absent profiling as completed tool work.
- [ ] **MAINT-OPT-016**: When a planned optimization collector does not
      complete, the system shall use the base maintenance partial-coverage
      outcome rather than report a clean or fully completed scan.
- [ ] **MAINT-OPT-017**: The system shall reuse MAINT-026 through MAINT-029 so
      repeated optimization findings create later occurrences rather than
      duplicate canonical findings or repair work.

## Assessment and Auto-Queue — #4495

- [ ] **MAINT-OPT-024**: The system shall obtain each semantic
      repair-eligibility assessment through `agent_harness` using a structured,
      versioned rubric with cited supporting and counterevidence.
- [ ] **MAINT-OPT-025**: The system shall restrict a repair-eligibility
      assessment standing to `strong`, `supported`, `exploratory`,
      `insufficient`, or `unknown`.
- [ ] **MAINT-OPT-026**: The system shall treat `unknown`, absent, malformed,
      stale, and wrong-rubric assessments as ineligible for automatic repair.
- [ ] **MAINT-OPT-027**: The system shall not use a raw analyzer confidence or
      a model probability as a calibrated automatic-repair authorization value.
- [ ] **MAINT-OPT-028**: The system shall compare an assessment standing to a
      captured ordered minimum deterministically without numerically
      aggregating standings.
- [ ] **MAINT-OPT-029**: The system shall default an elected automatic-repair
      minimum standing to `supported`.
- [ ] **MAINT-OPT-030**: The system shall expose all findings in the completed
      report whether or not they meet an elected automatic-repair minimum.
- [ ] **MAINT-OPT-031**: The system shall keep automatic repair off by default
      and require an explicit authorized per-run election at run start.
- [ ] **MAINT-OPT-032**: The system shall capture the elected minimum standing
      and explicit per-repair cost and time caps in the immutable run snapshot.
- [ ] **MAINT-OPT-033**: The system shall not make automatic repair a tenant-,
      project-, recipe-, or schedule-wide default.
- [ ] **MAINT-OPT-034**: The system shall queue an elected automatic repair
      only through the existing authorized M04 repair pathway with source
      report and canonical-finding provenance.
- [ ] **MAINT-OPT-035**: The system shall queue an elected automatic repair
      only when the source report outcome is `completed`.
- [ ] **MAINT-OPT-036**: When a source report outcome is `partial`,
      `cancelled`, or `budget_exhausted`, the system shall queue no automatic
      repair and shall record the non-dispatch reason.
- [ ] **MAINT-OPT-037**: The system shall require the catalog standing to be
      `auto_eligible` before an elected automatic repair may queue.
- [ ] **MAINT-OPT-038**: The system shall allow a run-start election to narrow
      but never widen a catalog repair standing.
- [ ] **MAINT-OPT-039**: The system shall require each automatic repair's scope
      to remain bounded to its approved finding and its captured cost/time caps.
- [ ] **MAINT-OPT-040**: When the repair target revision has moved, the system
      shall revalidate the finding through M04 before applying its
      recommendation.
- [ ] **MAINT-OPT-041**: When revalidation fails, the system shall preserve and
      visibly report the failure without applying or silently dropping repair.
- [ ] **MAINT-OPT-042**: The system shall prevent a repeated occurrence of the
      same canonical finding identity from queueing duplicate repair work.
- [ ] **MAINT-OPT-043**: When an automatic repair exhausts a captured budget,
      the system shall preserve collected evidence under the base maintenance
      budget-exhaustion contract.

## Staged Types and Security Boundary — #4496

- [ ] **MAINT-OPT-050**: The system shall set `security_hardening` to
      `manual_only` and shall not auto-queue its findings regardless of
      assessment standing.
- [ ] **MAINT-OPT-051**: The system shall require a dedicated owner-approved
      accuracy and safety review before changing the Security Hardening repair
      standing.
- [ ] **MAINT-OPT-052**: The system shall initially set Cost / Resource
      Efficiency, Design / Architecture, and Test Coverage & Quality to
      `default_deny` for automatic repair.
- [ ] **MAINT-OPT-053**: The system shall require owner authorization and
      evaluation evidence before changing a staged type from `default_deny`,
      and shall reconcile Test Coverage & Quality with RDR-075's test-quality
      recipe instead of duplicating its contract.
