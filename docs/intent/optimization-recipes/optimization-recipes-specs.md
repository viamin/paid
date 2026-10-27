# EARS: Optimization Recipes

> **Draft — pending design acceptance.** These active-gap claims trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md). They do
> not authorize implementation or rollout. #4492 is tracking-only.

## Catalog and Scope — #4493

- [ ] **MAINT-OPT-001**: The system shall define a code-defined optimization
      catalog whose entries have an identifier, display metadata, metric hints,
      recipe pointer where applicable, and repair standing.
- [ ] **MAINT-OPT-002**: The catalog shall contain Performance,
      Design/Architecture, Code Duplication, Security Hardening,
      Cost/Resource Efficiency, Maintainability/Readability, and Test Coverage
      & Quality, and adding a type shall require no enum or migration.
- [ ] **MAINT-OPT-003**: The system shall expose equivalent optimization type
      selection and project-scoped authorization through UI, API, and MCP.
- [ ] **MAINT-OPT-004**: When a type is absent or unmapped, the system shall
      start a custom-objective investigation without failing and retain any
      unmapped value in the run snapshot.
- [ ] **MAINT-OPT-005**: The system shall retain selected type, objective,
      scope, guidance, limits, and recipe version immutably across retries.
- [ ] **MAINT-OPT-006**: The system shall accept paths, symbols, or a
      free-form natural-language target as scope and resolve a named target
      before claiming coverage.
- [ ] **MAINT-OPT-007**: Scope shall bound recommendations but not supporting
      evidence access; an action beyond requested scope shall require human
      authorization and shall not qualify for automatic repair.

## First Recipes and Honest Evidence — #4494

- [ ] **MAINT-OPT-010**: Each recipe shall define objective, instructions,
      applicable evidence collectors, validation guidance, and metric hints.
- [ ] **MAINT-OPT-011**: Where a tool is used, the system shall record its
      name, version, and configuration on the finding and report.
- [ ] **MAINT-OPT-012**: Where no tool applies, the system shall complete a
      prompt-first investigation and disclose the absence of tool evidence.
- [ ] **MAINT-OPT-013**: The system shall not recommend consolidation or
      deletion solely from duplication output and shall record considered
      independence, framework callback, or dynamic-invocation counterevidence.
- [ ] **MAINT-OPT-014**: The system shall preserve base finding evidence and
      canonical-finding occurrence identity and shall record recipe evaluation
      evidence on at least one non-Paid project before delivery closes.

## Assessment and Bounded Automatic Repair — #4495

- [ ] **MAINT-OPT-020**: The system shall obtain repair eligibility through a
      structured, versioned `agent_harness` assessment and shall not derive it
      from finding text, category, or raw tool confidence.
- [ ] **MAINT-OPT-021**: The assessment shall record finding, rubric version,
      ordered standing, explanation, and citations; its standing shall be
      `strong`, `supported`, `exploratory`, `insufficient`, or `unknown`.
- [ ] **MAINT-OPT-022**: The system shall compare standings by order rather
      than numeric conversion and shall fail closed for unknown, absent,
      malformed, wrong-rubric, wrong-occurrence, or stale assessments.
- [ ] **MAINT-OPT-023**: Automatic repair shall be off by default and elected
      only per run at start; it shall not be a tenant, project, recipe, or
      schedule default, and non-electing runs shall remain report-only.
- [ ] **MAINT-OPT-024**: The system shall snapshot the election, minimum
      standing, and explicit per-repair cost/time caps at run start.
- [ ] **MAINT-OPT-025**: The default minimum standing shall be `supported`,
      and an election may only require a stricter standing.
- [ ] **MAINT-OPT-026**: The system shall automatically dispatch only an
      `auto_eligible` type finding from a `completed` report, through the base
      repair-handoff pathway, and shall link source report and canonical
      finding identity.
- [ ] **MAINT-OPT-027**: For a partial, cancelled, or budget-exhausted report,
      the system shall dispatch no automatic repair and shall record why.
- [ ] **MAINT-OPT-028**: Before an automatic repair applies to a moved target
      revision, the system shall revalidate evidence against its checkout and
      visibly surface a failure.
- [ ] **MAINT-OPT-029**: The system shall not dispatch duplicate automatic
      repair for a canonical finding identity with a queued or completed
      automatic repair, and shall preserve/report evidence on budget exhaustion.
- [ ] **MAINT-OPT-030**: The system shall leave the full report and unselected
      findings available for manual selection and shall require human
      authorization for a repair action beyond its approved finding.
- [ ] **MAINT-OPT-031**: When `maintenance_runs` is disabled, the system shall
      queue no new automatic repair and shall not cancel in-flight repair runs
      or delete reports.

## Staged Types — #4496

- [ ] **MAINT-OPT-040**: The `security_hardening` type shall be `manual_only`
      and shall never automatically dispatch repair until separately authorized
      by an accuracy and safety review.
- [ ] **MAINT-OPT-041**: Every newly staged type shall start `default_deny` and
      change standing only through separate owner authorization and its own
      evaluation evidence.
- [ ] **MAINT-OPT-042**: The test-coverage-quality recipe shall reconcile with
      RDR-075's planned test-quality recipe and shall not create a divergent
      second investigation.
