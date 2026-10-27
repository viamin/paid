# EARS: Optimization Recipes and Bounded Repair Election

> **Preparation draft — pending owner acceptance.** These active-gap claims
> trace to `optimization-recipes-design.md`; they are not implementation
> authority. `Tracks #4636`: keep its Inbox acceptance decision open until a
> human accepts and merges the canonical artifacts.

## Catalog and Scope — #4493

- [ ] **MAINT-OPT-001**: The system shall define the seven initial optimization
      types as code-defined catalog entries carrying display name,
      investigation description, metric hints, and an underlying recipe
      reference where one exists.
- [ ] **MAINT-OPT-002**: The system shall present the catalog as an optional
      type menu with equivalent project-scoped authorization in the UI,
      authenticated API, and MCP start surfaces.
- [ ] **MAINT-OPT-003**: When a user starts an optimization run without a type,
      the system shall admit the valid custom-objective maintenance request
      rather than requiring a catalog selection.
- [ ] **MAINT-OPT-004**: When a selected type has no mapped catalog recipe,
      the system shall retain it as a custom-objective maintenance run rather
      than rejecting the request.
- [ ] **MAINT-OPT-005**: The system shall snapshot the selected type with the
      base maintenance objective, scope, guidance, recipe version, and pinned
      revision, and shall retain that snapshot across retries.

## Initial Recipes and Honest Evidence — #4494

- [ ] **MAINT-OPT-010**: The system shall define Code Duplication,
      Maintainability / Readability, and Performance recipes with objective,
      instructions, evidence collectors where applicable, validation guidance,
      and metric hints.
- [ ] **MAINT-OPT-011**: When a duplication or complexity collector contributes
      to a finding, the system shall retain its version and configuration as
      provenance with the report evidence.
- [ ] **MAINT-OPT-012**: The system shall not recommend consolidation or
      deletion solely from similarity or absent static references; the semantic
      assessment shall account for counterevidence including intended
      independence and dynamic framework invocation.
- [ ] **MAINT-OPT-013**: When Performance has no applicable evidence collector,
      the system shall complete it as a prompt-first assessment and disclose
      that coverage honestly.
- [ ] **MAINT-OPT-014**: The system shall retain repeated optimization findings
      through MAINT-026 and MAINT-027 rather than creating duplicate repair
      work.

## Bounded Automatic Repair Election — #4495

- [ ] **MAINT-OPT-020**: The system shall default every optimization run to
      report-only and shall accept automatic repair only through an explicit,
      per-run election captured at start; no tenant, project, recipe, or
      catalog default shall enable it.
- [ ] **MAINT-OPT-021**: Where an election is offered, the system shall expose
      the same confidence-band threshold and explicit per-repair cost/time
      budgets through UI, authenticated API, and MCP surfaces with equivalent
      authorization.
- [ ] **MAINT-OPT-022**: The system shall obtain meaning-based finding
      assessment and eligibility-band assignment through `agent_harness` in a
      structured response retaining evidence and counterevidence; code shall
      not infer eligibility from text, keywords, or tool scores.
- [ ] **MAINT-OPT-023**: The system shall treat an eligibility band as an
      ordered policy category rather than a calibrated numeric probability,
      and shall use only the captured threshold ordering for deterministic
      eligibility filtering.
- [ ] **MAINT-OPT-024**: Before auto-queueing a finding, the system shall
      deterministically enforce the captured election, `maintenance_runs`
      guard, permitted category, threshold, explicit budget, repair-pathway
      authorization, provenance, and idempotency gates.
- [ ] **MAINT-OPT-025**: When any automatic-dispatch gate fails or is
      unavailable, the system shall retain a visible non-dispatch outcome and
      reason; it shall not silently drop the finding.
- [ ] **MAINT-OPT-026**: When an elected finding qualifies after report
      completion, the system shall queue repair only through MAINT-070–073,
      bounded to that finding and linked to its source report and identity.
- [ ] **MAINT-OPT-027**: If the repair checkout revision differs from the
      source report revision, the system shall revalidate the finding evidence
      before applying its recommendation; stale or failed revalidation shall
      prevent automatic repair.
- [ ] **MAINT-OPT-028**: The system shall enforce captured cost and time limits
      independently for every auto-queued repair run and preserve collected
      evidence when a limit is exhausted.
- [ ] **MAINT-OPT-029**: The system shall not auto-queue duplicate repair work
      for the same canonical finding identity and repair lineage.

## Staged Follow-ons — #4496

- [ ] **MAINT-OPT-030**: The system shall add Security Hardening, Cost /
      Resource Efficiency, Design / Architecture, and Test Coverage & Quality
      only as catalog-backed staged recipes following their evaluation evidence.
- [ ] **MAINT-OPT-031**: The system shall keep Security Hardening findings
      report-only and available only for manual repair selection until a
      separately accepted security-repair policy authorizes otherwise.
- [ ] **MAINT-OPT-032**: The system shall exclude Security Hardening from
      MAINT-OPT-024's permitted automatic-repair categories regardless of
      confidence band or election.
- [ ] **MAINT-OPT-033**: When a staged recipe has no credible collector, the
      system shall report its prompt-first evidence and coverage limitations
      honestly.
- [ ] **MAINT-OPT-034**: Before defining Test Coverage & Quality, the system
      shall reconcile its recipe contract with RDR-075's test-quality recipe
      so the system does not create duplicate maintenance behavior.
