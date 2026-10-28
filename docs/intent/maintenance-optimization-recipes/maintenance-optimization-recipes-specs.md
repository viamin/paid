# EARS: Maintenance Optimization Recipes and Bounded Repair Policy

> **Draft — pending design acceptance.** These specs refine the draft
> `maintenance-runs` leaf and are preparation only. They authorize neither
> maintenance runtime admission nor an automatic repair rollout. Each remains
> an active gap until owner acceptance of the canonical artifacts and the
> independent RDR-075 prerequisites.

## Catalog and Selection — #4493 (OPT-01)

- [ ] **MAINT-OPT-001**: The system shall define the seven initial maintenance
      optimization catalog entries — Performance, Design / Architecture, Code
      Duplication, Security Hardening, Cost / Resource Efficiency,
      Maintainability / Readability, and Test Coverage & Quality — as
      versioned recipe data with display name, description, objective,
      investigation instructions, applicable evidence collectors, validation
      guidance, and default metric hints.
- [ ] **MAINT-OPT-002**: When an authorized user starts a maintenance run from
      the UI, authenticated API, or MCP surface, the system shall expose the
      same catalog selection and compose it with optional guidance and scope
      under MAINT-011 through MAINT-015.
- [ ] **MAINT-OPT-003**: When a maintenance start request supplies an unmapped
      optimization type, the system shall admit it as a custom-objective run
      when its remaining MAINT-011 admission requirements are satisfied,
      rather than failing solely because the catalog has no matching entry.
- [ ] **MAINT-OPT-004**: The system shall snapshot the resolved catalog entry,
      recipe version, and elected optimization policy revision at maintenance
      run start and retain them across retries.

## Recipe Evidence and Scope — #4494 (OPT-02) and #4496 (OPT-04)

- [ ] **MAINT-OPT-010**: The system shall provide Code Duplication,
      Maintainability / Readability, and Performance recipes under #4494;
      duplication and maintainability collectors shall retain their tool
      provenance when available, and Performance shall complete prompt-first
      with explicit coverage disclosure when no collector is available.
- [ ] **MAINT-OPT-011**: The system shall provide Security Hardening, Cost /
      Resource Efficiency, Design / Architecture, and Test Coverage & Quality
      recipes under #4496 as staged catalog entries, and shall record
      prompt-first evidence and unavailable collector coverage honestly.
- [ ] **MAINT-OPT-012**: When an optimization recipe inspects supporting
      callers, tests, framework entry points, or design records outside its
      requested scope, the system shall retain that inspection as evidence but
      shall explain any recommendation outside requested scope and shall not
      expand an automatic repair beyond the approved finding.
- [ ] **MAINT-OPT-013**: The system shall preserve the MAINT-020 through
      MAINT-029 report, coverage, evidence, counterevidence, occurrence, and
      canonical-finding identity contracts for every optimization recipe.

## Semantic Assessment — #4494 (OPT-02) and #4496 (OPT-04)

- [ ] **MAINT-OPT-020**: When an optimization recipe assesses a finding, the
      system shall obtain its semantic claim assessment through `agent_harness`
      and record the evidence, counterevidence, policy-defined ordered
      confidence level, proposed bounded scope, validation plan, and reasoned
      eligibility recommendation.
- [ ] **MAINT-OPT-021**: The system shall not derive an optimization finding's
      semantic assessment or automatic-handoff eligibility from keywords, raw
      analyzer confidence, or an application-defined calibrated numeric score.
- [ ] **MAINT-OPT-022**: When an automatic-handoff policy uses a confidence
      threshold, the system shall snapshot an ordered confidence vocabulary and
      minimum level with the run, and shall compare the `agent_harness`
      assessment only against that declared order; the threshold shall not be
      represented as a calibrated probability or correctness guarantee.

## Opt-In Bounded Automatic Repair — #4495 (OPT-03)

- [ ] **MAINT-OPT-030**: The system shall default optimization maintenance runs
      to report-only behavior and shall accept automatic repair handoff only as
      an explicit per-run election from equivalently authorized UI,
      authenticated API, and MCP start surfaces; no tenant, schedule, catalog,
      or recipe default shall enable the election.
- [ ] **MAINT-OPT-031**: When a user elects automatic repair handoff, the
      system shall snapshot the minimum confidence level, explicit per-repair
      cost and time limits, and policy revision with the maintenance run.
- [ ] **MAINT-OPT-032**: When an elected optimization report completes, the
      system shall dispatch a qualifying non-security finding only through the
      MAINT-070 through MAINT-072 bounded repair pathway after deterministic
      checks confirm feature admission, repair-path authorization, contained
      scope, snapshotted confidence eligibility, explicit budget, fresh or
      successfully revalidated evidence, and no existing repair for that
      canonical finding identity and policy revision.
- [ ] **MAINT-OPT-033**: If an elected automatic-handoff gate fails, then the
      system shall retain the report and finding evidence and expose a visible
      non-dispatch outcome identifying the failed gate, rather than silently
      dropping the finding or creating repair work.
- [ ] **MAINT-OPT-034**: When an auto-queued repair target revision differs
      from the source report revision, the system shall revalidate the finding
      before applying its recommendation; failed, inconclusive, or unavailable
      revalidation shall preserve evidence and prevent the repair from using
      stale evidence.
- [ ] **MAINT-OPT-035**: The system shall exclude Security Hardening findings
      from automatic repair handoff and shall leave their repair selection
      manual-only until a separately accepted security policy authorizes an
      extension.
- [ ] **MAINT-OPT-036**: Where `maintenance_runs` is disabled after an elected
      optimization run starts, the system shall stop new automatic handoffs
      while retaining reports and allowing already-created repair runs to
      follow their normal lifecycle.

## Delivery Mapping

- #4492 is tracking-only and owns no executable behavior.
- #4493 implements MAINT-OPT-001 through MAINT-OPT-004.
- #4494 implements MAINT-OPT-010, MAINT-OPT-012 through MAINT-OPT-013, and
  MAINT-OPT-020 through MAINT-OPT-022 for the initial recipes.
- #4495 implements MAINT-OPT-030 through MAINT-OPT-036.
- #4496 implements MAINT-OPT-011 through MAINT-OPT-013 and MAINT-OPT-020
  through MAINT-OPT-022 for staged recipes, preserving MAINT-OPT-035.
