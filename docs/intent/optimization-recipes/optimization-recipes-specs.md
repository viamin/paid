# EARS: Maintenance Optimization Recipes

> **Draft — pending owner acceptance.** These active-gap claims trace to
> `optimization-recipes-design.md`. They authorize no implementation until
> this policy and RDR-075 are accepted.

## Catalog and Scope — #4493, #4494

- [ ] **MAINT-OPT-001**: The system shall maintain a versioned optimization
      recipe catalog whose entries declare objective, category, evidence
      collectors, semantic-assessment rubric, validation guidance, and
      automatic-repair standing.
- [ ] **MAINT-OPT-002**: When a maintenance run selects an optimization
      recipe, the system shall snapshot the recipe version, requested scope,
      guidance, collector configuration, and limits at admission.
- [ ] **MAINT-OPT-003**: The system shall permit an authorized user to select
      a recipe or submit a free-text optimization question without making a
      recipe a tenant, project, or schedule default.
- [ ] **MAINT-OPT-004**: When supporting evidence requires inspection beyond
      requested scope, the system shall record that inspected context
      separately from requested scope and recommendation scope.
- [ ] **MAINT-OPT-005**: When a recommendation or repair would exceed
      requested scope, the system shall require explicit human authorization
      before it is queued or applied.
- [ ] **MAINT-OPT-006**: The system shall deliver the full report, including
      findings that are ineligible for automatic repair.

## Evidence and Assessment — #4494

- [ ] **MAINT-OPT-020**: The system shall use `agent_harness` to produce a
      structured semantic assessment with rubric version, ordered standing,
      explanation, cited evidence, counterevidence, and validation plan for
      each candidate finding considered for repair.
- [ ] **MAINT-OPT-021**: The system shall treat raw collector confidence as
      provenance and shall not use it as an automatic-repair eligibility gate.
- [ ] **MAINT-OPT-022**: The system shall accept only `supported`,
      `marginal`, `unsupported`, or `unknown` as an assessment standing and
      shall fail closed when the assessment is malformed, missing, stale, or
      `unknown`.
- [ ] **MAINT-OPT-023**: The system shall compare an elected threshold only
      to the ordered assessment standing and shall not represent that
      threshold as a calibrated numerical probability.

## Bounded Automatic Repair — #4495

- [ ] **MAINT-OPT-040**: The system shall keep automatic repair off by
      default and shall admit it only through an authorized per-run election
      recorded at run start.
- [ ] **MAINT-OPT-041**: When an automatic-repair election is recorded, the
      system shall snapshot a minimum standing of `supported` and explicit
      cost and time caps for each repair run.
- [ ] **MAINT-OPT-042**: When a report outcome is `completed`, the system
      shall auto-queue a repair only through the existing maintenance repair
      pathway and only when authorization, category standing, assessment
      threshold, approved scope, budget, and idempotency gates all pass.
- [ ] **MAINT-OPT-043**: When a report outcome is `clean`, `partial`,
      `cancelled`, or `budget_exhausted`, the system shall auto-queue no
      repair and shall retain the reason for non-dispatch.
- [ ] **MAINT-OPT-044**: When an auto-queued repair target revision differs
      from the source report revision, the system shall revalidate its finding
      against the repair checkout before applying the recommendation.
- [ ] **MAINT-OPT-045**: When auto-repair revalidation fails or is incomplete,
      the system shall visibly prevent application and preserve the repair's
      collected evidence.
- [ ] **MAINT-OPT-046**: The system shall use canonical finding identity as
      the auto-queue idempotency key and shall not queue duplicate repair work
      for repeated occurrences of that finding.

## Category Admission — #4496

- [ ] **MAINT-OPT-047**: The system shall classify security-hardening findings
      as `manual_only` and shall not auto-queue them until a separately
      authorized safety and accuracy review changes that standing.
- [ ] **MAINT-OPT-048**: The system shall classify cost, design/architecture,
      and test-coverage optimization types as `default_deny` and shall not
      auto-queue them until separate owner authorization with evaluation
      evidence changes their standing.
- [ ] **MAINT-OPT-049**: The system shall not allow a run-start election,
      recipe configuration, or schedule configuration to override a
      `manual_only` or `default_deny` category standing.
