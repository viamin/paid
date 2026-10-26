# EARS: Optimization Recipes and Bounded Repair Policy

> **Draft — pending owner acceptance.** These claims are docs-only preparation
> for [#4636](https://github.com/viamin/paid/issues/4636). They do not enable
> maintenance or repair runtime behavior. Every claim remains an active gap
> until the accepted artifacts merge and its mapped implementation issue lands.

## Catalog and Selection — #4493

- [ ] **OPT-001**: The system shall define the optimization type catalog as
      code-defined entries containing a stable key, display name, investigation
      description, metric hints, and an optional recipe definition, so adding a
      type does not require a run-contract enum migration.
- [ ] **OPT-002**: When an authorized caller starts a maintenance run through
      the UI, authenticated API, or MCP surface, the system shall expose the
      same curated optimization type menu and project-scoped authorization
      decision on every surface.
- [ ] **OPT-003**: When a caller selects a catalog type, the system shall
      snapshot that selection with the objective, scope, guidance, pinned
      revision, and recipe version and retain it across retries.
- [ ] **OPT-004**: If a caller omits or supplies an unmapped optimization type,
      then the system shall admit a custom-objective maintenance run subject to
      the base admission contract rather than rejecting the request.

## Recipes, Scope, and Evidence — #4494 and #4496

- [ ] **OPT-010**: The system shall register code duplication,
      maintainability/readability, and performance as first-slice optimization
      recipes, recording attached collector provenance and prompt-only coverage
      limitations honestly on every report and finding.
- [ ] **OPT-011**: When an optimization recommendation depends on supporting
      evidence outside requested scope, the system shall record that evidence
      in the report, shall keep the recommendation within the requested scope,
      and shall require explicit human authorization before a repair expands it.
- [ ] **OPT-012**: When a finding needs semantic assessment, the system shall
      obtain a structured assessment through `agent_harness` using bounded
      pinned-revision evidence and persist its claim, counterevidence,
      eligibility disposition, policy/rubric version, and explanation.
- [ ] **OPT-013**: The system shall treat Security Hardening, Cost / Resource
      Efficiency, Design / Architecture, and Test Coverage & Quality as staged
      catalog recipes, and shall reconcile Test Coverage & Quality with the
      RDR-075 test-quality recipe before implementation.

## Bounded Auto-Queue — #4495

- [ ] **OPT-020**: The system shall default optimization auto-queue to off and
      shall allow an authorized caller to elect it only per maintenance run,
      snapshotting the policy/rubric version and explicit repair cost/time
      limits at run start.
- [ ] **OPT-021**: When Rails evaluates an auto-queue candidate, it shall use
      the persisted `agent_harness` eligibility disposition only after
      deterministically validating response structure, feature-guard state,
      election authorization, repair-path authorization, category exclusion,
      budgets, revision freshness, and idempotency; it shall not derive
      eligibility from text, tool output, or a Rails-calibrated numeric score.
- [ ] **OPT-022**: When an elected, eligible non-security finding has a repair
      target revision different from its report revision, the system shall
      revalidate the finding against the repair checkout before applying its
      recommendation, and shall visibly prevent repair on failed revalidation.
- [ ] **OPT-023**: The system shall atomically reserve auto-queued repair work
      by the run election and canonical finding identity so repeated finding
      occurrences cannot create duplicate repair runs.
- [ ] **OPT-024**: The system shall exclude Security Hardening findings from
      auto-queue and retain them for manual selection only until a separately
      accepted security-repair policy authorizes a different behavior.
- [ ] **OPT-025**: Where maintenance admission is disabled, the system shall
      prevent new optimization auto-queue elections and dispatches without
      cancelling active repair runs or deleting reports.
