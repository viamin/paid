# EARS: Maintenance Optimization Recipes

> **Draft — pending design acceptance.** These specs trace to
> [`maintenance-optimization-design.md`](maintenance-optimization-design.md),
> itself an overlay on the draft
> [`maintenance-runs`](../maintenance-runs/maintenance-runs-specs.md)
> contracts and draft
> [`RDR-075`](../../rdrs/RDR-075-general-maintenance-runs.md). All specs
> below are `[ ]` active gaps: correct, current intent with no
> implementation yet. None are implementable until this segment and the
> base design are accepted
> ([#4635](https://github.com/viamin/paid/issues/4635),
> [#4636](https://github.com/viamin/paid/issues/4636)). Runtime
> deliverables are mapped to
> [#4493](https://github.com/viamin/paid/issues/4493)–[#4496](https://github.com/viamin/paid/issues/4496);
> [#4492](https://github.com/viamin/paid/issues/4492) is the tracking
> umbrella only. Where a family spec rides a base contract, the base
> `MAINT` ID is cited rather than restated as family policy.

## Recipe Catalog (OPT-01, #4493)

- [ ] **MAINT-OPT-001**: The system shall define a code-defined
      optimization type catalog whose initial entries are Performance,
      Design / Architecture, Code Duplication, Security Hardening,
      Cost / Resource Efficiency, Maintainability / Readability, and Test
      Coverage & Quality, each carrying a display name, a description of
      what the agent looks for, default metric hints, and a pointer to the
      underlying recipe definition when one exists.
- [ ] **MAINT-OPT-002**: The system shall allow a new optimization type to
      be added by a catalog entry (plus its recipe definition when ready)
      without an enum migration or a change to the maintenance run
      contract.
- [ ] **MAINT-OPT-003**: The system shall surface the optimization type
      menu wherever maintenance runs are started — the UI trigger form,
      chat, and the API/MCP surfaces — applying the same project-scoped
      start authorization on every surface (rides `MAINT-010`).
- [ ] **MAINT-OPT-004**: The system shall keep a maintenance run startable
      without a selected optimization type.
- [ ] **MAINT-OPT-005**: When an optimization type is selected, the system
      shall record it on the run snapshot at start, shall not mutate it
      after the run starts, and shall retain it across retries (rides
      `MAINT-015`).
- [ ] **MAINT-OPT-006**: When a supplied type value has no catalog entry,
      the system shall degrade to a custom-objective maintenance run
      rather than failing the start request.
- [ ] **MAINT-OPT-007**: The system shall allow an optimization type
      selection to compose with a free-form natural-language scope and
      with all other maintenance start inputs.
- [ ] **MAINT-OPT-008**: While the `maintenance_runs` guard is disabled
      for a project's tenant, the system shall refuse optimization runs
      identically on every surface, and a rollback shall keep existing
      reports readable and active runs cancellable (rides `MAINT-002`,
      `MAINT-004`).
- [ ] **MAINT-OPT-009**: In the first delivery the system shall provide no
      project-admin authoring surface for the type catalog; the catalog is
      code-defined and versioned with the application.

## Recipe Execution (OPT-02, #4494)

- [ ] **MAINT-OPT-010**: The system shall define each recipe through an
      objective, investigation instructions, applicable evidence
      collectors, validation guidance, and default metric hints per the
      catalog contract.
- [ ] **MAINT-OPT-011**: The system shall register the first three
      optimization recipes — Code Duplication, Maintainability /
      Readability, and Performance — with catalog entries and, where a
      tool attached, record tool name/version/configuration provenance on
      the findings and report (rides `MAINT-043`).
- [ ] **MAINT-OPT-012**: The system shall resolve duplication evidence
      through RDR-073 attachments or the base native-CLI analyzer contract
      with no family-specific matching engine (rides `MAINT-040`,
      `MAINT-041`).
- [ ] **MAINT-OPT-013**: The system shall not propose a consolidation or
      deletion finding from analyzer similarity output alone: deliberate
      independence, framework callbacks, reflection, external APIs, and
      compatibility obligations shall be weighed through semantic
      assessment before the finding is proposed.
- [ ] **MAINT-OPT-014**: The system shall support the Maintainability /
      Readability recipe with complexity evidence where a tool attaches
      and agent assessment otherwise, with each finding carrying a
      proposed action.
- [ ] **MAINT-OPT-015**: The system shall support the Performance recipe
      as prompt-first with no blocking analyzer dependency, and shall
      disclose prompt-only coverage honestly when no tool attaches (rides
      `MAINT-044`).
- [ ] **MAINT-OPT-016**: The system shall record every optimization
      finding occurrence with the base findings contract — category,
      locations/symbols, claim, supporting evidence, counterevidence,
      proposed action, and verification disposition (rides `MAINT-025`).
- [ ] **MAINT-OPT-017**: When a repeated optimization scan reproduces a
      finding with the same identity, the system shall update that
      canonical finding's occurrences without duplicating repair work
      (rides `MAINT-026`, `MAINT-027`).
- [ ] **MAINT-OPT-018**: The system shall record the recipe's default
      metric hints on the findings they apply to.

## Scope and Honest Evidence (#4492, #4494)

- [ ] **MAINT-OPT-020**: The system shall accept a free-form
      natural-language scope (files, a feature, a page in the app) for an
      optimization run and shall impose no family-specific scope limits
      (rides the reconciled `MAINT-011`).
- [ ] **MAINT-OPT-021**: The system shall treat the requested scope as
      bounding recommendations, not evidence access: callers, tests,
      framework entry points, and design documents may be inspected
      outside the requested scope to validate a claim.
- [ ] **MAINT-OPT-022**: When a recommendation requires changes beyond the
      requested scope, the system shall explain that expansion in the
      report and shall require explicit authorization before repair scope
      expands.
- [ ] **MAINT-OPT-023**: When an investigation ran prompt-only, the system
      shall record prompt-only evidence honestly and shall never record
      tool provenance for evidence no tool produced.
- [ ] **MAINT-OPT-024**: The system shall record the resolved scope and
      any exclusions on the report, distinct from the requested scope
      (rides `MAINT-014`).
- [ ] **MAINT-OPT-025**: The system shall distinguish actionable findings,
      unresolved candidates, deliberate exceptions, and coverage
      limitations in every optimization report, and shall never present
      incomplete coverage as `clean` or `completed` (rides `MAINT-021`,
      `MAINT-022`).

## Semantic Assessment (Zero Framework Cognition)

- [ ] **MAINT-OPT-030**: The system shall keep semantic judgment — whether
      a candidate is a real finding, whether evidence supports repair,
      whether independence is deliberate — in LLM calls through
      `agent_harness` with structured response schemas, and shall not
      implement those judgments as keyword, regex, or structural-proxy
      branching in control-plane code.
- [ ] **MAINT-OPT-031**: The system shall record a verification
      disposition on every finding occurrence that is distinct from any
      raw tool-confidence score (rides `MAINT-025`).
- [ ] **MAINT-OPT-032**: The system shall assign each finding a
      repair-eligibility standing that is exactly one of `supported`,
      `marginal`, `unsupported`, or `unknown`.
- [ ] **MAINT-OPT-033**: The system shall record the standing rubric
      version and assessment model provenance with every
      repair-eligibility assessment.
- [ ] **MAINT-OPT-034**: The system shall treat `unknown` standing as
      never qualifying for automatic repair under any configuration, and
      as distinct from `unsupported`.

## Bounded Automatic Repair (OPT-03, #4495)

- [ ] **MAINT-OPT-040**: The system shall offer the automatic-repair
      election only as a per-run choice at maintenance run start on the
      UI, API, and MCP surfaces, and shall treat an omitted election
      exactly as report-only.
- [ ] **MAINT-OPT-041**: The system shall record the election at run start
      with a minimum repair-eligibility standing (default `supported`)
      and explicit per-repair cost/time caps, shall not mutate the
      election after run start, and shall allow the election only to
      narrow what automatic repair may queue — never to widen a catalog
      standing of `manual_only` or `default_deny`.
- [ ] **MAINT-OPT-042**: The system shall evaluate automatic queuing only
      when the report outcome is `completed`; a `partial`, `cancelled`, or
      `budget_exhausted` report shall queue nothing and shall record why
      (rides `MAINT-020`).
- [ ] **MAINT-OPT-043**: When a report completes with qualifying findings,
      the system shall dispatch bounded repair runs through the existing
      base repair pathways with provenance links back to the source report
      and finding identities (rides `MAINT-070`, `MAINT-072`).
- [ ] **MAINT-OPT-044**: If the repair target's revision has changed since
      the source report was generated, the system shall require
      revalidation before any auto-queued repair applies, and shall
      surface revalidation failures visibly rather than silently dropping
      them (rides `MAINT-071`).
- [ ] **MAINT-OPT-045**: The system shall enforce the elected cost/time
      caps per auto-queued repair run and shall preserve collected
      evidence on exhaustion (rides `MAINT-024`).
- [ ] **MAINT-OPT-046**: The system shall key automatic-repair idempotency
      on the canonical finding identity, so a repeated occurrence of the
      same identity never queues duplicate repair work.
- [ ] **MAINT-OPT-047**: The system shall exclude findings whose catalog
      type carries `manual_only` automatic-repair standing from automatic
      queuing under any election; Security Hardening shall carry
      `manual_only` until a separately authorized accuracy and safety
      review admits it.
- [ ] **MAINT-OPT-048**: The system shall register the staged types —
      Cost / Resource Efficiency, Design / Architecture, and Test
      Coverage & Quality — with `default_deny` automatic-repair standing,
      changeable only by separate owner authorization with evaluation
      evidence.

## Selection Threshold and Rollout Semantics (OPT-03, #4495)

- [ ] **MAINT-OPT-050**: The system shall treat the repair-eligibility
      standings as a discrete order — `supported` above `marginal` above
      `unsupported`, with `unknown` outside the order — and shall compare
      the configured minimum against that order.
- [ ] **MAINT-OPT-051**: The system shall use a raw analyzer or model
      confidence score never as the selection-threshold input; only the
      discrete repair-eligibility standing shall be compared against the
      configured minimum.
- [ ] **MAINT-OPT-052**: The system shall not represent the selection
      threshold as a calibrated probability; it is an ordinal standing
      comparison, and no family surface shall display or accept a numeric
      confidence threshold for automatic repair.
- [ ] **MAINT-OPT-053**: The system shall deliver the report in full
      regardless of the election, and findings below the threshold shall
      remain available for manual repair selection through the unchanged
      base handoff (rides `MAINT-018`, `MAINT-070`).
- [ ] **MAINT-OPT-054**: While the `maintenance_runs` guard is disabled
      for a project's tenant, the system shall stop new auto-queues
      without cancelling active repair runs and without deleting reports
      (rides `MAINT-004`).
- [ ] **MAINT-OPT-055**: The system shall not dispatch any auto-queued
      repair run that lacks an explicit per-repair budget recorded at
      election time.
- [ ] **MAINT-OPT-056**: The system shall derive the repair-eligibility
      standing from the finding's verification disposition and evidence
      assessment in the report that produced it, and shall not recompute
      or upgrade a standing outside a run's own assessment pipeline.
