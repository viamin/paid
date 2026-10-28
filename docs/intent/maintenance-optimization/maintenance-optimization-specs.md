# EARS: Maintenance Optimization Recipes

> **Draft — pending owner acceptance.** These active-gap claims trace to
> [`maintenance-optimization-design.md`](maintenance-optimization-design.md).
> They describe no shipped runtime behavior and cannot be implemented until
> the owner accepts and merges this policy, base maintenance intent is accepted,
> and the independent RDR-075 prerequisites are satisfied.

## OPT-01 — Catalog and Selection (#4493)

- [ ] **MAINT-OPT-001**: The system shall define the optimization type catalog
      in code with stable entries for performance, design/architecture, code
      duplication, security hardening, cost/resource efficiency,
      maintainability/readability, and test coverage/quality; every entry
      shall include a display name, description, metric hints, and an optional
      recipe-definition pointer.
- [ ] **MAINT-OPT-002**: When an authorized user starts a maintenance run
      while `maintenance_runs` is enabled, the UI, authenticated API, and MCP
      surfaces shall expose the same optimization catalog selection and the
      same project-scoped authorization decision.
- [ ] **MAINT-OPT-003**: When an optimization catalog selection is absent, the
      system shall admit the request under the base maintenance objective rule;
      when a supplied selection is unmapped, the system shall preserve it as a
      custom-objective maintenance request rather than reject the start or
      grant a catalog recipe's policy.
- [ ] **MAINT-OPT-004**: When an optimization selection starts a maintenance
      run, the system shall snapshot the selected entry, resolved recipe
      version, scope, guidance, collector configuration, and metric hints, and
      shall retain that provenance across retries.

## OPT-02 — Recipe Evidence and Assessment (#4494)

- [ ] **MAINT-OPT-010**: The system shall define duplication,
      maintainability/readability, and performance recipes with investigation
      instructions, compatible evidence collectors, validation guidance, and
      metric hints, using the base maintenance report and finding contracts.
- [ ] **MAINT-OPT-011**: When an optimization recipe has no applicable
      collector, the system shall record a prompt-first investigation and its
      coverage honestly; it shall not represent a missing tool check as a
      completed tool check.
- [ ] **MAINT-OPT-012**: When an optimization finding needs a semantic
      assessment, the system shall obtain the assessment through
      `agent_harness` in a structured response that includes supporting and
      counterevidence, recommendation scope, and repair eligibility; it shall
      not derive those semantic judgments from analyzer scores, keywords, or
      prose parsing in framework code.
- [ ] **MAINT-OPT-013**: When evaluating a duplication finding, the system
      shall require assessment of intentional independence, framework
      callbacks, and dynamic invocation before recommending consolidation; a
      similarity observation alone shall not establish the recommendation.

## OPT-03 — Bounded Automatic Repair (#4495)

- [ ] **MAINT-OPT-040**: The system shall keep optimization auto-queue
      disabled by default and shall permit it only when an authorized user
      explicitly elects a per-run policy at maintenance-run start; omission
      shall preserve report-only behavior.
- [ ] **MAINT-OPT-041**: When an authorized user elects optimization
      auto-queue, the system shall snapshot the selected recipe, a versioned
      minimum ordered assessment band, and explicit cost and time caps for
      each repair run; the assessment band shall not assert a calibrated
      numerical probability or be calculated from raw analyzer confidence.
- [ ] **MAINT-OPT-042**: When a completed optimization report has a finding
      eligible for auto-queue, the system shall deterministically require an
      enabled maintenance guard, valid per-run authorization snapshot, elected
      recipe membership, open finding state, structurally valid agent-harness
      assessment at or above the snapshot band, non-security category, and
      proposed repair scope no broader than the finding before creating repair
      work through the existing authorized repair pathway.
- [ ] **MAINT-OPT-043**: When an auto-queued repair is created, the system
      shall apply the elected explicit cost and time caps, link it to its
      source report and canonical finding, and preserve evidence on budget
      exhaustion.
- [ ] **MAINT-OPT-044**: When the repair checkout revision differs from the
      source report revision, the system shall revalidate the selected finding
      before applying its recommendation; a failed or inconclusive
      revalidation shall be visible and shall not apply stale evidence or
      silently queue a replacement.
- [ ] **MAINT-OPT-045**: When report completion is processed more than once
      for the same elected run and canonical finding, the system shall create
      at most one auto-queued repair using a transactional idempotency key
      derived from the run, finding identity, and policy snapshot.
- [ ] **MAINT-OPT-046**: When an eligible repair requires a scope broader than
      its finding's claim and affected symbols, the system shall require new
      explicit human authorization rather than auto-queue it.
- [ ] **MAINT-OPT-047**: While maintenance admission is disabled, the system
      shall stop new optimization auto-queues without deleting reports or
      cancelling repair runs already active through the repair lifecycle.

## OPT-04 — Staged Follow-on Recipes (#4496)

- [ ] **MAINT-OPT-060**: The system shall register security hardening,
      cost/resource efficiency, design/architecture, and test coverage/quality
      as staged optimization catalog entries using the same recipe and honest
      evidence contracts as the initial optimization recipes.
- [ ] **MAINT-OPT-061**: When an optimization finding has the security
      hardening category, the system shall preserve it for report inspection
      and manual repair selection only, and shall exclude it from auto-queue
      until a separately accepted security-repair policy authorizes it.
- [ ] **MAINT-OPT-062**: When designing the test coverage/quality recipe, the
      system shall reconcile its objective and evidence collectors with the
      RDR-075 test-quality recipe rather than create a duplicate maintenance
      objective.
