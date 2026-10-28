# EARS: Optimization Recipes

> **Draft — pending design acceptance.** These active-gap specs trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md), the draft
> RDR-075 design, and the base `maintenance-runs` contracts. They authorize no
> implementation until both design packages are accepted and merged. Each
> section names its delivery issue; [#4492](https://github.com/viamin/paid/issues/4492)
> is tracking only and owns no executable claim.

## Catalog and Type Menu — [#4493](https://github.com/viamin/paid/issues/4493)

- [ ] **MAINT-OPT-001**: The system shall define a code-defined optimization
      recipe catalog whose entries carry stable identifier, display name,
      description, default metric hints, recipe pointer when present, and
      repair standing.
- [ ] **MAINT-OPT-002**: The catalog shall contain Performance,
      Design/Architecture, Code Duplication, Security Hardening,
      Cost/Resource Efficiency, Maintainability/Readability, and Test Coverage
      & Quality.
- [ ] **MAINT-OPT-003**: Adding a catalog type shall require a catalog entry
      only, not an enum change or database migration.
- [ ] **MAINT-OPT-004**: The UI, authenticated API, and MCP surface shall
      expose equivalent type-menu entries and project-scoped start
      authorization.
- [ ] **MAINT-OPT-005**: When no optimization type is selected, the system
      shall start a custom-objective investigation without failing the start.
- [ ] **MAINT-OPT-006**: When an unrecognized type is selected, the system
      shall record that value and start a custom-objective investigation
      without failing the start.
- [ ] **MAINT-OPT-007**: The system shall record the selected type identifier
      with objective, scope, and guidance in the immutable run snapshot.
- [ ] **MAINT-OPT-008**: The system shall retain selected and unmapped type
      values across retries of the same run.
- [ ] **MAINT-OPT-009**: When `maintenance_runs` is disabled, the system shall
      refuse optimization-type maintenance admission identically on UI, API,
      and MCP.

## Scope — [#4493](https://github.com/viamin/paid/issues/4493), [#4494](https://github.com/viamin/paid/issues/4494)

- [ ] **MAINT-OPT-010**: The system shall accept paths, symbols, or a
      free-form natural-language target as an optimization scope without
      limiting its breadth.
- [ ] **MAINT-OPT-011**: When scope names a natural-language target, the
      system shall resolve it before any check claims coverage.
- [ ] **MAINT-OPT-012**: The report shall record actual resolved scope and
      exclusions separately from requested scope.
- [ ] **MAINT-OPT-013**: Scope shall bound recommendations, not supporting
      evidence an investigation may inspect.
- [ ] **MAINT-OPT-014**: When a proposed action exceeds requested scope, the
      system shall require explicit human authorization and exclude it from
      automatic repair.

## Recipe Execution and Honest Evidence — [#4494](https://github.com/viamin/paid/issues/4494)

- [ ] **MAINT-OPT-015**: Each recipe shall supply objective, investigation
      instructions, applicable evidence collectors, validation guidance, and
      default metric hints.
- [ ] **MAINT-OPT-016**: When a recipe uses a tool, the system shall record
      analyzer name, version, and configuration as finding and report
      provenance.
- [ ] **MAINT-OPT-017**: When no applicable tool exists, the system shall
      complete prompt-first and disclose that no tool evidence was collected.
- [ ] **MAINT-OPT-018**: The system shall not recommend consolidation or
      deletion from duplication output alone, and shall record considered
      deliberate independence, callbacks, or dynamic invocation.
- [ ] **MAINT-OPT-019**: Each optimization finding shall record category,
      locations/symbols, claim, supporting and counterevidence, proposed
      action, validation plan, and verification disposition distinct from raw
      tool confidence.
- [ ] **MAINT-OPT-020**: The system shall record a recipe's metric hints on
      findings that recipe produces.
- [ ] **MAINT-OPT-021**: When all planned checks complete with no findings,
      the system shall report the successful `clean` outcome.
- [ ] **MAINT-OPT-022**: When a repeated scan observes the same canonical
      finding identity, the system shall create its later occurrence without
      duplicate repair work.
- [ ] **MAINT-OPT-023**: Before a recipe delivery closes, the system shall
      record its evaluation evidence on at least one non-Paid project,
      including actionable findings, false positives, unresolved coverage,
      latency, token/tool cost, and repeated-finding noise.

## Semantic Repair-Eligibility Assessment — [#4495](https://github.com/viamin/paid/issues/4495)

- [ ] **MAINT-OPT-024**: The system shall obtain repair-eligibility standing
      from a structured `agent_harness` assessment against a versioned rubric,
      and shall not derive it from text, category, analyzer confidence, or
      pattern matching.
- [ ] **MAINT-OPT-025**: The assessment shall record canonical finding,
      rubric version, standing, explanation, and supporting citations.
- [ ] **MAINT-OPT-026**: A standing shall be `strong`, `supported`,
      `exploratory`, `insufficient`, or `unknown`.
- [ ] **MAINT-OPT-027**: The system shall compare standings by defined order
      and shall not convert one to a numeric score.
- [ ] **MAINT-OPT-028**: The system shall treat `unknown` as ineligible for
      automatic repair under every configuration.
- [ ] **MAINT-OPT-029**: The system shall fail closed when an assessment is
      absent, malformed, has an unknown rubric version, or is bound to another
      finding occurrence.
- [ ] **MAINT-OPT-030**: When occurrence evidence materially changes, the
      system shall re-assess and shall not act on the stale assessment.

## Bounded Automatic Repair — [#4495](https://github.com/viamin/paid/issues/4495)

- [ ] **MAINT-OPT-031**: Automatic repair shall be off by default, elected
      per run at run start, and never enabled by tenant, project, or recipe
      default.
- [ ] **MAINT-OPT-032**: When a run does not elect automatic repair, the
      system shall behave exactly as report-only.
- [ ] **MAINT-OPT-033**: The UI, authenticated API, and MCP surface shall
      expose equivalent election, minimum-standing, and default per-repair
      cost/time-cap inputs with equivalent authorization.
- [ ] **MAINT-OPT-034**: The system shall store election, minimum standing,
      and per-repair caps immutably in the run snapshot.
- [ ] **MAINT-OPT-035**: The default minimum standing shall be `supported`.
- [ ] **MAINT-OPT-036**: A run election shall apply the stricter of its
      minimum standing and the configured default minimum.
- [ ] **MAINT-OPT-037**: The system shall not permit a maintenance schedule
      to elect automatic repair.
- [ ] **MAINT-OPT-038**: Each type repair standing shall be `auto_eligible`,
      `manual_only`, or `default_deny`.
- [ ] **MAINT-OPT-039**: The system shall change a type repair standing only
      through separately recorded owner authorization and shall never widen it
      through a run election.
- [ ] **MAINT-OPT-040**: The system shall dispatch automatic repair only from
      a source report whose outcome is `completed`.
- [ ] **MAINT-OPT-041**: When a source report is `partial`, `cancelled`, or
      `budget_exhausted`, the system shall dispatch no automatic repair and
      shall record why.
- [ ] **MAINT-OPT-042**: The system shall deliver the full report regardless
      of selected findings and retain unselected findings for manual repair.
- [ ] **MAINT-OPT-043**: The system shall use the base repair-handoff pathway
      and link every automatic repair to source report and canonical finding.
- [ ] **MAINT-OPT-044**: When the repair revision moved, the system shall
      revalidate evidence against the repair checkout and visibly surface a
      failed revalidation.
- [ ] **MAINT-OPT-045**: The system shall not dispatch a second automatic
      repair for a canonical finding identity with queued or completed
      automatic repair work.
- [ ] **MAINT-OPT-046**: Each automatic repair shall carry explicit cost and
      time caps and preserve/report evidence on exhaustion.
- [ ] **MAINT-OPT-047**: An automatic repair's scope shall remain bounded to
      its approved finding; wider work requires explicit human authorization.
- [ ] **MAINT-OPT-048**: When `maintenance_runs` is disabled, the system shall
      queue no new automatic repair and shall neither cancel active repairs nor
      delete reports.

## Staged Optimization Types — [#4496](https://github.com/viamin/paid/issues/4496)

- [ ] **MAINT-OPT-049**: Each staged type shall register through the catalog
      with metadata, applicable collectors, and metric hints without enum or
      migration work.
- [ ] **MAINT-OPT-050**: `security_hardening` shall be `manual_only` and its
      findings shall be available only for manual repair selection.
- [ ] **MAINT-OPT-051**: A newly staged type shall start `default_deny` and
      change only through separately recorded owner authorization.
- [ ] **MAINT-OPT-052**: The system shall not automatically repair a finding
      whose type is `manual_only` or `default_deny`, regardless of assessed
      standing.
- [ ] **MAINT-OPT-053**: `test_coverage_quality` shall reconcile with
      RDR-075's planned test-quality recipe and shall not create a divergent
      second investigation.
