# EARS: Optimization Recipes

> **Accepted intent; implementation gaps.** These active-gap claims trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md) and draft
> RDR-075. Owner acceptance is recorded in
> [#4636](https://github.com/viamin/paid/issues/4636#issuecomment-6534710003).
> Base maintenance acceptance and normal delivery gates still apply. #4492
> is tracking only and owns none of the claims.

## Catalog and Type Menu — [#4493](https://github.com/viamin/paid/issues/4493)

- [ ] **MAINT-OPT-001**: The system shall define a code-defined optimization recipe registry whose entries carry a stable identifier, display name, investigation description, metric hints, recipe pointer, and repair standing.
- [ ] **MAINT-OPT-002**: The system shall include Performance, Design/Architecture, Code Duplication, Security Hardening, Cost/Resource Efficiency, Maintainability/Readability, and Test Coverage & Quality as initial types.
- [ ] **MAINT-OPT-003**: Adding a type shall require a catalog entry only, not an enum change or migration.
- [ ] **MAINT-OPT-004**: When starting maintenance, UI, authenticated API, and MCP shall expose equivalent type-menu entries and project-scoped authorization.
- [ ] **MAINT-OPT-005**: When no type is selected, the system shall start a custom-objective investigation.
- [ ] **MAINT-OPT-006**: When a selected type is unmapped, the system shall start a custom-objective investigation, record that value, and not fail selection alone.
- [ ] **MAINT-OPT-007**: The system shall snapshot the selected type beside objective, scope, and guidance and not mutate it after start.
- [ ] **MAINT-OPT-008**: The system shall retain selected and unmapped type values across retries.
- [ ] **MAINT-OPT-009**: When `maintenance_runs` is disabled, the system shall identically refuse optimization-run admission on UI, API, and MCP.

## Scope — [#4493](https://github.com/viamin/paid/issues/4493), [#4494](https://github.com/viamin/paid/issues/4494)

- [ ] **MAINT-OPT-010**: The system shall accept paths, symbols, or free-form natural-language targets without limiting the target's breadth.
- [ ] **MAINT-OPT-011**: When a scope names a natural-language target, the system shall resolve it before claiming coverage.
- [ ] **MAINT-OPT-012**: The system shall record resolved investigated scope and exclusions separately from requested scope.
- [ ] **MAINT-OPT-013**: Scope shall bound recommendations, not supporting evidence inspection.
- [ ] **MAINT-OPT-014**: When proposed action exceeds requested scope, the system shall require explicit human authorization and exclude it from automatic repair.

## Recipe Execution and Honest Evidence — [#4494](https://github.com/viamin/paid/issues/4494)

- [ ] **MAINT-OPT-015**: Each recipe shall define objective, instructions, applicable collectors, validation guidance, and metric hints.
- [ ] **MAINT-OPT-016**: When a recipe uses a tool, the system shall record its name, version, and configuration as report/finding provenance.
- [ ] **MAINT-OPT-017**: When no applicable tool exists, the system shall complete prompt-first and disclose absent tool evidence.
- [ ] **MAINT-OPT-018**: The system shall not recommend consolidation/deletion solely from duplication output and shall record considered independence, callbacks, or dynamic invocation.
- [ ] **MAINT-OPT-019**: The system shall record category, locations/symbols, claim, supporting and counterevidence, action, validation plan, and a disposition distinct from raw tool confidence for each finding.
- [ ] **MAINT-OPT-020**: The system shall record a recipe's metric hints on its findings.
- [ ] **MAINT-OPT-021**: When every planned check completes with no finding, the system shall report a successful clean outcome.
- [ ] **MAINT-OPT-022**: When repeated scans observe a canonical finding, the system shall create the current occurrence without duplicate repair work.
- [ ] **MAINT-OPT-023**: The system shall retain external-project recipe evaluation evidence for findings, false positives, coverage, latency, cost, repeated-finding noise, and repair-review outcomes.
- [ ] **MAINT-OPT-023A**: The system shall block a recipe's delivery close until at least one project other than Paid has recorded evaluation evidence covering every category in MAINT-OPT-023, and shall identify the qualifying project(s) in that evidence.

## Semantic Repair-Eligibility Assessment — [#4495](https://github.com/viamin/paid/issues/4495)

- [ ] **MAINT-OPT-024**: The system shall obtain eligibility standing from a structured, versioned `agent_harness` assessment, never text/category matching or raw analyzer confidence.
- [ ] **MAINT-OPT-025**: The assessment shall record canonical finding, rubric version, standing, explanation, and supporting citations.
- [ ] **MAINT-OPT-026**: The standing shall be `strong`, `supported`, `exploratory`, `insufficient`, or `unknown`.
- [ ] **MAINT-OPT-027**: The system shall compare standings by their defined order and shall not convert them to numeric scores.
- [ ] **MAINT-OPT-028**: The system shall treat `unknown` as ineligible under every configuration.
- [ ] **MAINT-OPT-029**: The system shall fail closed for absent, malformed, wrong-rubric, or wrong-occurrence assessments.
- [ ] **MAINT-OPT-030**: When occurrence evidence materially changes, the system shall reassess rather than act on the former assessment.

## Bounded Automatic Repair — [#4495](https://github.com/viamin/paid/issues/4495)

- [ ] **MAINT-OPT-031**: Automatic repair shall be off by default, elected per run at start, and never tenant-, project-, or recipe-wide.
- [ ] **MAINT-OPT-032**: Without an election, the system shall behave as report-only.
- [ ] **MAINT-OPT-033**: UI, API, and MCP shall equivalently surface election, minimum standing, and per-repair cost/time caps.
- [ ] **MAINT-OPT-034**: The system shall snapshot election, effective minimum standing, and per-repair caps at run start without mutation.
- [ ] **MAINT-OPT-035**: The default minimum standing shall be `supported`.
- [ ] **MAINT-OPT-036**: The system shall apply the stricter of elected and configured minimum standings.
- [ ] **MAINT-OPT-037**: The system shall not permit a maintenance schedule to elect automatic repair.
- [ ] **MAINT-OPT-038**: Each type repair standing shall be `auto_eligible`, `manual_only`, or `default_deny`.
- [ ] **MAINT-OPT-039**: The system shall change a type standing only through separate recorded owner authorization and never widen it through election.
- [ ] **MAINT-OPT-040**: The system shall auto-dispatch only findings from a `completed` report.
- [ ] **MAINT-OPT-041**: For `partial`, `cancelled`, or `budget_exhausted` reports, the system shall dispatch nothing and record why.
- [ ] **MAINT-OPT-042**: The system shall deliver the complete report and leave unselected findings available for manual selection.
- [ ] **MAINT-OPT-043**: The system shall dispatch through the base repair-handoff pathway and link report and canonical finding.
- [ ] **MAINT-OPT-044**: When the repair revision moved, the system shall revalidate against the repair checkout and visibly surface failure.
- [ ] **MAINT-OPT-045**: The system shall not dispatch a second automatic repair for a canonical finding with queued or completed automatic repair.
- [ ] **MAINT-OPT-046**: Each automatic repair shall have explicit cost/time caps and preserve/report evidence on exhaustion.
- [ ] **MAINT-OPT-047**: Automatic repair shall stay within the approved finding; expansion requires explicit human authorization.
- [ ] **MAINT-OPT-048**: When the rollout guard is disabled, the system shall queue no new automatic repair and retain reports/in-flight repairs.

## Staged Optimization Types — [#4496](https://github.com/viamin/paid/issues/4496)

- [ ] **MAINT-OPT-049**: Each staged type shall register catalog metadata, collectors, and metric hints without enum or migration changes.
- [ ] **MAINT-OPT-050**: `security_hardening` shall be `manual_only` and report findings for manual selection only.
- [ ] **MAINT-OPT-051**: A newly staged type shall begin `default_deny` and change only with recorded owner authorization.
- [ ] **MAINT-OPT-052**: The system shall never auto-dispatch `manual_only` or `default_deny` types regardless of assessed standing.
- [ ] **MAINT-OPT-053**: `test_coverage_quality` shall reconcile with RDR-075's test-quality recipe and not define a divergent investigation.
