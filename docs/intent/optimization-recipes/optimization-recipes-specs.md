# EARS: Optimization Recipe Catalog and Bounded Repair Policy

> **Draft — pending design acceptance.** These claims trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md) and
> remain `[ ]` until accepted base maintenance intent and this policy have
> merged, implementation prerequisites are satisfied, and tests exist.
> They are documentation-only preparation for [#4636](https://github.com/viamin/paid/issues/4636),
> which **Tracks #4636** pending a human Inbox acceptance decision; they do
> not enable `maintenance_runs`, a recipe, or automatic repair.

## Catalog and Selection — #4493

- [ ] **OPT-001**: The system shall provide a code-defined optimization
      catalog whose entries have a stable key, display name, investigation
      description, metric hints, and an optional underlying recipe pointer.
- [ ] **OPT-002**: The system shall expose Performance, Design / Architecture,
      Code Duplication, Security Hardening, Cost / Resource Efficiency,
      Maintainability / Readability, and Test Coverage & Quality as the initial
      curated optimization catalog entries.
- [ ] **OPT-003**: When an authorized user starts a maintenance run from the
      UI, authenticated API, or MCP surface, the system shall apply the same
      catalog-selection and project authorization contract on every surface
      and snapshot the selected type with the base maintenance request.
- [ ] **OPT-004**: If an optimization type selection is unmapped or omitted,
      then the system shall use the custom-objective maintenance path rather
      than reject a request that otherwise satisfies `MAINT-011`.

## First Recipes and Evidence — #4494

- [ ] **OPT-010**: The system shall define Code Duplication, Maintainability /
      Readability, and Performance as the first optimization recipes using the
      base maintenance recipe, report, finding, and provenance contracts.
- [ ] **OPT-011**: When an optimization recipe assesses a candidate finding,
      the system shall obtain its semantic assessment, reasoning,
      counterevidence, proposed bounded action, and structured policy
      eligibility assessment through `agent_harness`, rather than infer them
      from text or tool metrics in control-plane code.
- [ ] **OPT-012**: When an optimization recipe uses evidence outside the
      requested scope to support or reject a recommendation, the system shall
      identify that evidence and explain any recommended change beyond the
      requested scope in the report.
- [ ] **OPT-013**: If a planned optimization evidence collector is unavailable
      or incomplete, then the system shall report partial coverage under
      `MAINT-020`–`MAINT-024`; where no credible collector is planned, it shall
      report the prompt-first limitation honestly rather than represent tool
      coverage it did not obtain.

## Opt-In Bounded Auto-Queue — #4495

- [ ] **OPT-020**: The system shall keep optimization auto-queue disabled by
      default and shall accept an explicit, per-run election only through the
      same authorized UI, authenticated API, and MCP start contracts.
- [ ] **OPT-021**: When an elected optimization report completes, the system
      shall evaluate only the structured `agent_harness` eligibility assessment
      against the configured policy threshold and shall not assign a calibrated
      numerical meaning in application code.
- [ ] **OPT-022**: When a finding satisfies the elected policy, the system
      shall authorize an auto-queued repair only after the `maintenance_runs`
      guard, existing repair-path authorization, explicit per-repair cost/time
      budget, canonical finding identity, and idempotency gates all pass.
- [ ] **OPT-023**: The system shall create an auto-queued optimization repair
      through the existing bounded repair pathway with links to its source
      report and canonical finding, rather than mutate source code as a scan
      side effect.
- [ ] **OPT-024**: While an existing repair already represents the same
      canonical finding under the same auto-queue policy, the system shall not
      queue duplicate repair work for a repeated finding occurrence.
- [ ] **OPT-025**: If the repair checkout revision differs from the source
      report revision, then the system shall require and visibly record
      revalidation before the auto-queued repair applies its recommendation.
- [ ] **OPT-026**: If an auto-queue authorization, budget, idempotency, or
      revalidation gate fails, then the system shall retain the report and
      finding, surface the blocking reason, and shall not silently queue or
      silently discard repair work.
- [ ] **OPT-027**: Where `maintenance_runs` is disabled after optimization
      work has started, the system shall stop new auto-queues without deleting
      reports or cancelling active repair runs.

## Staged Follow-Ons — #4496

- [ ] **OPT-030**: The system shall add Security Hardening, Cost / Resource
      Efficiency, Design / Architecture, and Test Coverage & Quality only as
      catalog entries and recipes that retain the base maintenance evidence and
      provenance contracts.
- [ ] **OPT-031**: While a finding is categorized as Security Hardening, the
      system shall exclude it from optimization auto-queue and require manual
      repair selection until a dedicated security repair policy is accepted.
- [ ] **OPT-032**: Where a follow-on optimization recipe lacks a credible tool
      evidence path, the system shall use and disclose prompt-first assessment
      rather than claim tool-assisted coverage.
- [ ] **OPT-033**: When defining the Test Coverage & Quality recipe, the
      system shall reconcile it with RDR-075's planned test-quality recipe
      rather than create a duplicate maintenance objective.
