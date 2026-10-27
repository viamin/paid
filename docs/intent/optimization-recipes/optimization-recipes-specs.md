# EARS: Optimization Recipes and Bounded Repair Election

> **Draft — pending design acceptance.** These claims trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md), the
> draft RDR-075 maintenance LLD, and the draft RDR-075. They are active gaps,
> not runtime authorization. `MAINT-073` remains report-only unless this
> separately accepted policy is merged with the base maintenance artifacts.

## Catalog and Scope

- [ ] **OPT-001**: The system shall define the initial Optimization catalog as
      code-defined entries for Performance, Design / Architecture, Code
      Duplication, Security Hardening, Cost / Resource Efficiency,
      Maintainability / Readability, and Test Coverage & Quality; each entry
      shall provide a display name, assessment description, metric hints, and
      an optional recipe reference. [#4493]
- [ ] **OPT-002**: When an authorized user starts a maintenance run, the
      system shall expose equivalent optimization-type selection through UI,
      API, and MCP, combine it with optional free-text scope and guidance,
      and retain the selected type in the immutable run snapshot. [#4493]
- [ ] **OPT-003**: If an optimization type has no mapped recipe, then the
      system shall start a custom-objective maintenance run rather than reject
      the request. [#4493]
- [ ] **OPT-004**: When an optimization recipe assesses a requested scope,
      the system shall bound recommendations to that resolved scope while
      allowing relevant callers, tests, and entry points as supporting
      evidence, and shall disclose evidence gathered outside the scope. [#4494]

## Evidence and Semantic Assessment

- [ ] **OPT-010**: The system shall define each optimization recipe with an
      objective, assessment instructions, applicable evidence collectors,
      validation guidance, and metric hints, and shall record collector or
      prompt-only provenance and coverage limits on its report. [#4494]
- [ ] **OPT-011**: The system shall obtain the semantic assessment of an
      optimization finding through `agent_harness` as a structured response
      containing claim, supporting evidence, counterevidence, verification
      disposition, bounded repair scope, and policy vocabulary assessment
      tier. [#4494]
- [ ] **OPT-012**: The system shall not derive an optimization finding's
      semantic assessment tier from keywords, counts, or raw analyzer
      confidence in application code; application code shall only validate the
      response structure and enforce configured deterministic policy gates.
      [#4494]
- [ ] **OPT-013**: When an evidence collector does not complete, the system
      shall preserve the incomplete coverage in the maintenance report and
      shall not represent the result as clean or fully completed. [#4494]

## Bounded Repair Election

- [ ] **OPT-020**: The system shall keep optimization maintenance runs
      report-only when no repair election is supplied and shall default every
      repair election to off; it shall never use a tenant-wide or recipe-level
      election default. [#4495]
- [ ] **OPT-021**: When an authorized user elects auto-queue at run start,
      the system shall snapshot a policy assessment-tier threshold and
      explicit per-repair cost and time limits, and shall expose the same
      election authorization and inputs through UI, API, and MCP. [#4495]
- [ ] **OPT-022**: On a `completed` optimization report, the system shall
      request a bounded repair through the existing M04 pathway only when the
      maintenance guard is enabled, both required authorizations pass, the
      election exists, the finding is open and structurally assessed at or
      above the elected tier, the repair scope is bounded to the finding, and
      explicit limits are present. [#4495]
- [ ] **OPT-023**: Before an auto-queued repair applies a recommendation, if
      its target revision differs from the report revision, then the system
      shall revalidate the finding against the repair checkout; a failed
      revalidation or scope expansion shall stop the repair visibly without
      applying stale evidence. [#4495]
- [ ] **OPT-024**: The system shall enforce each auto-queued repair's explicit
      cost and time limits, preserve its evidence on exhaustion, and record
      the report, occurrence, canonical-finding identity, election, gate
      result, and repair-run or failure outcome. [#4495]
- [ ] **OPT-025**: When a canonical finding identity has an active or
      completed auto-queued repair in the same election lineage, the system
      shall not queue another repair for a repeated occurrence; it shall keep
      the new occurrence as report evidence. [#4495]
- [ ] **OPT-026**: If an elected finding fails an auto-queue gate, then the
      system shall expose the failed gate on the report and preserve manual
      repair selection rather than silently dropping the finding. [#4495]

## Staged Follow-ons

- [ ] **OPT-030**: The system shall register Security Hardening, Cost /
      Resource Efficiency, Design / Architecture, and Test Coverage & Quality
      as staged recipes through the same catalog and evidence contract. [#4496]
- [ ] **OPT-031**: The system shall keep Security Hardening findings
      report-only and eligible only for manual repair selection until a
      separately accepted security-repair policy authorizes otherwise. [#4496]
- [ ] **OPT-032**: When implementing Test Coverage & Quality, the system
      shall reconcile its recipe with RDR-075's test-quality objective rather
      than create a duplicate maintenance recipe. [#4496]
