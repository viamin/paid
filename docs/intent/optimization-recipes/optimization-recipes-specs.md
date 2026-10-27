# EARS: Optimization Recipe Family

> **Draft — pending design acceptance.** These specs trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md), itself
> a reviewable draft consuming the draft
> [`maintenance-runs` EARS](../maintenance-runs/maintenance-runs-specs.md)
> (`MAINT-*`) and the draft RDR-075 design (still Status: Draft). All specs
> below are `[ ]` active gaps: correct, current intent with no implementation
> yet. None are implementable until RDR-075, the maintenance-runs LLD/EARS,
> and this LLD/EARS pair are all accepted — see
> [#4636](https://github.com/viamin/paid/issues/4636),
> [#4635](https://github.com/viamin/paid/issues/4635), and
> [#4604](https://github.com/viamin/paid/issues/4604). Implementation is
> tracked at [#4493](https://github.com/viamin/paid/issues/4493)–
> [#4496](https://github.com/viamin/paid/issues/4496);
> [#4492](https://github.com/viamin/paid/issues/4492) is a tracking umbrella
> only and owns no spec below.

## Catalog and Type Menu

- [ ] **MAINT-OPT-001**: The system shall define the optimization type
      catalog as code-defined entries, not a database enum; adding a new
      type shall require a catalog entry only, never a migration.
- [ ] **MAINT-OPT-002**: The system shall include, at minimum, Performance,
      Code Duplication, Maintainability / Readability, Security Hardening,
      Cost / Resource Efficiency, Design / Architecture, and Test Coverage &
      Quality in the catalog, each carrying a display name, a description of
      what the agent looks for, default metric hints, and a pointer to its
      recipe definition when one exists.
- [ ] **MAINT-OPT-003**: The system shall surface the optimization type menu
      with equivalent behavior in the project UI trigger-agent-run form,
      chat, the authenticated API, and the MCP surface.
- [ ] **MAINT-OPT-004**: The system shall allow a maintenance run to start
      without an optimization type selected; type selection shall compose
      with, and never replace, the free-form natural-language scope field.
- [ ] **MAINT-OPT-005**: If a selected type has no mapped recipe or is
      otherwise unmapped, then the system shall degrade to a custom-objective
      maintenance run rather than refusing the request.
- [ ] **MAINT-OPT-006**: The system shall persist the selected optimization
      type on the run snapshot alongside objective, scope, and guidance, and
      shall retain it unchanged across retries.

## Recipes and Evidence

- [ ] **MAINT-OPT-020**: The system shall define each optimization recipe
      with an objective, investigation instructions, applicable evidence
      collectors, validation guidance, and default metric hints.
- [ ] **MAINT-OPT-021**: The Code Duplication recipe shall not report a
      consolidation or deletion recommendation derived solely from
      similarity or analyzer output when the investigation finds deliberate
      independence or framework/dynamic-dispatch behavior affecting the
      compared code.
- [ ] **MAINT-OPT-022**: The Maintainability / Readability recipe shall
      report complexity, naming, or documentation findings with a proposed
      action, using a tool-assisted complexity analyzer where one is
      attached and an agent assessment where none is.
- [ ] **MAINT-OPT-023**: The Performance recipe shall complete as a
      prompt-only investigation when no profiling tool is attached, and
      shall disclose that prompt-only coverage honestly in the report rather
      than presenting it as tool-verified.
- [ ] **MAINT-OPT-024**: Every optimization finding occurrence shall carry
      category, affected locations/symbols, claim, supporting evidence,
      known counterevidence, proposed action, validation plan, and a
      verification disposition kept distinct from any raw tool-confidence
      score, per the base maintenance occurrence contract.
- [ ] **MAINT-OPT-025**: When a repeated scan reproduces an optimization
      finding with the same canonical identity, the system shall create a
      new occurrence linked to the current report and shall not duplicate
      repair work for that canonical finding.
- [ ] **MAINT-OPT-026**: A completed optimization scan with full planned
      coverage and no findings shall report `clean`; a planned check that
      did not complete shall report `partial`, never `clean` or `completed`,
      per the base maintenance run-outcome contract.

## Bounded Automatic Repair

- [ ] **MAINT-OPT-030**: The system shall offer automatic repair queuing
      only as an explicit per-run election made at run start through the UI
      trigger form and the API/MCP surfaces, with equivalent authorization
      on every surface.
- [ ] **MAINT-OPT-031**: Automatic repair queuing shall default to disabled
      for every run; the system shall not derive a default-enabled state
      from tenant settings, project settings, or the selected recipe.
- [ ] **MAINT-OPT-032**: Where a run did not elect automatic repair queuing,
      the system shall behave identically to a report-only run with no
      additional dispatch logic invoked.
- [ ] **MAINT-OPT-033**: Where a run elected automatic repair queuing, the
      system shall request a verification-disposition assessment for each
      candidate finding through `agent_harness`, using the same qualitative
      disposition concept the base maintenance occurrence contract already
      records, rather than computing a numeric confidence score in
      application code.
- [ ] **MAINT-OPT-034**: The system shall dispatch a bounded repair run for
      a candidate finding only when its returned verification disposition
      meets or exceeds the project's configured minimum qualifying
      disposition, compared ordinally; the system shall not implement this
      comparison as score arithmetic.
- [ ] **MAINT-OPT-035**: The system shall retain every finding in the
      delivered report regardless of its verification disposition; a
      disposition below the configured minimum shall remain available for
      manual selection, never hidden or demoted.
- [ ] **MAINT-OPT-036**: The system shall assign each auto-queued repair run
      its own explicit cost and time budget limits, distinct from the
      originating maintenance run's budget.
- [ ] **MAINT-OPT-037**: When an auto-queued repair run exhausts its budget,
      the system shall preserve all evidence collected up to that point,
      per the base maintenance budget-exhaustion contract.
- [ ] **MAINT-OPT-038**: If the repair target's revision has changed since
      the source report was generated, then the system shall require
      revalidation of an auto-queued finding's evidence before applying its
      recommendation, identical to the manual-selection revalidation
      requirement; the system shall never apply a stale auto-queued
      recommendation silently.
- [ ] **MAINT-OPT-039**: The system shall not dispatch an auto-queued repair
      for a canonical finding identity that already has an active or
      completed repair link.
- [ ] **MAINT-OPT-040**: The system shall exclude security-category findings
      from automatic repair queuing unconditionally, independent of their
      verification disposition, until a separately authorized policy review
      changes this exclusion.
- [ ] **MAINT-OPT-041**: The system shall link every auto-queued repair run
      back to its source maintenance report and canonical finding, per the
      base maintenance repair-handoff contract.
- [ ] **MAINT-OPT-042**: The system shall treat the run-start election as
      satisfying the project-scoped repair-creation authorization for every
      finding that election later dispatches; it shall not require a
      second, separate authorization check at dispatch time against a
      different actor.
- [ ] **MAINT-OPT-043**: While the `maintenance_runs` guard is disabled for
      a project's tenant, the system shall not dispatch any new auto-queued
      repair run, while leaving already-active repair runs and existing
      reports unaffected.

## Staged Follow-on Types

- [ ] **MAINT-OPT-050**: The system shall register Security Hardening, Cost
      / Resource Efficiency, Design / Architecture, and Test Coverage &
      Quality through the same catalog contract (MAINT-OPT-001) with no
      enum or migration work per type.
- [ ] **MAINT-OPT-051**: The system shall apply the MAINT-OPT-040 automatic
      repair exclusion to Security Hardening findings from the type's first
      shipped evidence collector onward, with no separate implementation
      required to establish the exclusion.
