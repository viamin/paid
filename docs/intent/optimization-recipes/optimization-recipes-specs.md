# EARS: RDR-075 Optimization Recipes and Bounded Repair Policy

> **Draft — pending human design acceptance.** These specs trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md) and the
> draft RDR-075 maintenance contract. They are documentation-only preparation
> for #4493–#4496, authorize no runtime behavior, and do not enable the
> `maintenance_runs` guard.

## Catalog and Start Contract

- [ ] **OPT-001**: The system shall define the optimization catalog as
      code-defined entries, initially containing Performance, Design /
      Architecture, Code Duplication, Security Hardening, Cost / Resource
      Efficiency, Maintainability / Readability, and Test Coverage & Quality;
      each entry shall provide a display name, investigation description,
      default metric hints, and an optional recipe reference. (#4493)
- [ ] **OPT-002**: The system shall present the same optimization catalog
      selection with the same project-scoped authorization on the UI,
      authenticated API, and MCP maintenance-run start surfaces. (#4493)
- [ ] **OPT-003**: When no catalog type is selected, the system shall admit a
      maintenance run under the existing free-text objective contract; when a
      supplied type has no mapped catalog entry, it shall create a
      custom-objective maintenance run rather than reject admission. (#4493)
- [ ] **OPT-004**: The system shall snapshot a selected catalog entry or
      custom objective with the maintenance run's objective, scope, guidance,
      revision, and recipe inputs, and shall retain that snapshot on retry.
      (#4493)

## Recipe Evidence and Scope

- [ ] **OPT-010**: When an optimization run has requested scope, the system
      shall bound its recommendation to that scope while permitting documented
      inspection of callers, tests, framework entry points, design documents,
      and other corroborating repository context. (#4494, #4496)
- [ ] **OPT-011**: The system shall obtain semantic optimization assessment
      through `agent_harness` and record structured claim, supporting evidence,
      counterevidence, proposed action, validation plan, coverage limitations,
      and verification disposition for each finding. (#4494, #4496)
- [ ] **OPT-012**: The system shall present prompt-only or incomplete tool
      evidence honestly and shall not report `clean` or completed coverage when
      a planned evidence collector was incomplete, cancelled, or exhausted its
      budget. (#4494, #4496)
- [ ] **OPT-013**: The system shall provide Code Duplication,
      Maintainability / Readability, and Performance as the initial recipe
      implementations; it shall treat similarity, absent static references, or
      absent test coverage as candidate evidence rather than sufficient proof
      for consolidation or deletion. (#4494)
- [ ] **OPT-014**: The system shall add Security Hardening, Cost / Resource
      Efficiency, Design / Architecture, and Test Coverage & Quality only as
      staged catalog recipes; the Test Coverage & Quality recipe shall reuse or
      reconcile the RDR-075 test-quality design rather than duplicate it.
      (#4496)

## Bounded Automatic Repair

- [ ] **OPT-020**: The system shall treat omission of an optimization
      auto-queue election as report-only behavior and shall permit an
      auto-queue election only when an authorized user explicitly records it
      at that run's start; it shall not derive the election from a tenant-wide
      setting or recipe default. (#4495)
- [ ] **OPT-021**: The system shall snapshot an elected auto-queue policy's
      confidence threshold and explicit per-repair cost/time limits with its
      optimization run, and shall not mutate that policy after the run starts.
      (#4495)
- [ ] **OPT-022**: The system shall obtain each finding's confidence
      disposition from a schema-validated `agent_harness` assessment; framework
      code shall enforce only the snapshotted threshold's declared ordering and
      shall not invent, calibrate, or semantically infer a numeric confidence
      score. (#4495)
- [ ] **OPT-023**: After an optimization report completes, the system shall
      auto-queue a repair only through the existing M04 repair pathway when the
      maintenance guard, equivalent authorization, explicit election,
      threshold, bounded finding scope, and explicit per-repair budget gates
      all pass. (#4495)
- [ ] **OPT-024**: The system shall use the canonical finding identity to
      prevent repeated occurrences from auto-queuing duplicate repair work and
      shall link every auto-queued repair to its source report and finding.
      (#4495)
- [ ] **OPT-025**: When a repair checkout differs from the source report's
      target revision, the system shall revalidate the selected finding before
      applying its recommendation; failed revalidation or a scope expansion
      shall be visible and shall prevent the repair from proceeding. (#4495)
- [ ] **OPT-026**: The system shall preserve collected evidence when an
      auto-queued repair exhausts its explicit cost or time limit. (#4495)
- [ ] **OPT-027**: The system shall exclude Security Hardening findings from
      automatic repair and shall require manual selection through the existing
      M04 pathway unless a separately accepted security-repair policy changes
      that exclusion. (#4495, #4496)
