# EARS: Maintenance Optimization Recipes and Bounded Repair

> **Draft — owner acceptance required.** These active-gap claims trace to
> [`maintenance-optimization-design.md`](maintenance-optimization-design.md)
> and the draft RDR-075 maintenance contract. They do not authorize runtime
> behavior. #4492 tracks family coordination; #4493–#4496 own the executable
> deliverables.

## Catalog and Selection — #4493

- [ ] **MAINT-OPT-001**: The system shall provide catalog entries for performance, design/architecture, code duplication, security hardening, cost/resource efficiency, maintainability/readability, and test coverage/quality.
- [ ] **MAINT-OPT-002**: Each catalog entry shall define a stable key, display name, description, assessment instructions, evidence collectors, validation guidance, metric hints, and repair posture.
- [ ] **MAINT-OPT-003**: The system shall add an optimization type by adding a catalog entry, without an enum or schema migration.
- [ ] **MAINT-OPT-004**: When a selected catalog key is unknown, the system shall treat it as a custom-objective maintenance run rather than reject the request.
- [ ] **MAINT-OPT-005**: The UI, authenticated API, and MCP shall expose equivalent catalog selection and project-scoped authorization.
- [ ] **MAINT-OPT-006**: The system shall allow catalog selection to compose with free-form objective, scope, and guidance.
- [ ] **MAINT-OPT-007**: The system shall snapshot the resolved catalog entry and version on the maintenance run and retain it across retries.
- [ ] **MAINT-OPT-008**: Where `maintenance_runs` is disabled, the system shall refuse new catalog-selected runs on every surface.
- [ ] **MAINT-OPT-009**: The system shall record the selected type as recipe provenance without treating the type alone as evidence or repair authority.

## Recipe Evidence — #4494 and #4496

- [ ] **MAINT-OPT-010**: The system shall register code-duplication, maintainability/readability, and performance recipes through the catalog.
- [ ] **MAINT-OPT-011**: The code-duplication recipe shall preserve tool provenance and require semantic assessment to consider intentional independence, dynamic invocation, and counterevidence before a finding is actionable.
- [ ] **MAINT-OPT-012**: The maintainability/readability recipe shall treat complexity or style evidence as a candidate, not as proof that a change is warranted.
- [ ] **MAINT-OPT-013**: Where no applicable performance collector completes, the performance recipe shall perform a prompt-first assessment and report its coverage limitation.
- [ ] **MAINT-OPT-014**: The system shall preserve completed and unavailable collector provenance on every recipe report.
- [ ] **MAINT-OPT-015**: The system shall retain report occurrences and canonical finding identity across repeated recipe runs.
- [ ] **MAINT-OPT-016**: The system shall bound recommendations to selected scope while allowing cited supporting inspection outside that scope.
- [ ] **MAINT-OPT-017**: The system shall require explicit authorization before a proposed repair expands beyond a finding's approved scope.
- [ ] **MAINT-OPT-018**: The system shall route every semantic recipe assessment through `agent_harness` with structured evidence and counterevidence output.
- [ ] **MAINT-OPT-019**: The system shall not convert raw analyzer confidence or missing collector output into a semantic finding or clean coverage.
- [ ] **MAINT-OPT-020**: The system shall register security hardening, cost/resource efficiency, design/architecture, and test coverage/quality as staged catalog entries.
- [ ] **MAINT-OPT-021**: The security hardening recipe shall produce report-only findings and permit only manual repair selection.
- [ ] **MAINT-OPT-022**: The cost/resource-efficiency recipe shall report prompt-first evidence honestly when no credible collector applies.
- [ ] **MAINT-OPT-023**: The design/architecture recipe shall frame recommendations as evidence-backed proposals rather than deterministic violations.
- [ ] **MAINT-OPT-024**: The test coverage/quality recipe shall reuse the maintenance test-quality contract rather than create a parallel finding lifecycle.
- [ ] **MAINT-OPT-025**: The staged recipes shall remain unavailable for automatic repair until their catalog posture is separately authorized.
## Bounded Automatic Repair — #4495

- [ ] **MAINT-OPT-040**: The system shall expose a per-run `auto_queue_bounded_repairs` election, minimum assessment standing, and explicit per-repair cost/time caps on UI, API, and MCP with equivalent authorization.
- [ ] **MAINT-OPT-041**: The system shall default the election to false and the minimum standing to `supported`; a run-start choice may only narrow, never broaden, the catalog policy.
- [ ] **MAINT-OPT-042**: The system shall consider automatic repair only after a `completed` maintenance report.
- [ ] **MAINT-OPT-043**: The system shall never auto-queue from a `clean`, `partial`, `cancelled`, or `budget_exhausted` report.
- [ ] **MAINT-OPT-044**: The system shall obtain the finding's semantic assessment and discrete `unsupported`, `uncertain`, or `supported` standing through `agent_harness` and retain cited evidence and counterevidence.
- [ ] **MAINT-OPT-045**: The system shall preserve raw tool confidence separately and shall not interpret a standing as calibrated numeric confidence.
- [ ] **MAINT-OPT-046**: The system shall form an automatic-repair idempotency key from canonical finding identity and the repair-policy snapshot, and shall not queue duplicate active or completed repair work for that key.
- [ ] **MAINT-OPT-047**: The system shall exclude security-hardening findings from automatic repair and require manual selection until a separately accepted policy changes that exclusion.
- [ ] **MAINT-OPT-048**: The system shall default cost/resource efficiency, design/architecture, and test coverage/quality to automatic-repair denial until their postures are separately authorized.
- [ ] **MAINT-OPT-049**: Before queueing, the system shall enforce the base guard, recorded election, catalog posture, standing threshold, bounded scope, explicit caps, current revalidation, and idempotency gate deterministically.
- [ ] **MAINT-OPT-050**: The system shall submit an admitted automatic repair only through the existing authorized M04 repair pathway with source report and finding provenance.
- [ ] **MAINT-OPT-051**: If the repair target revision or material evidence changed since the source report, then the system shall require successful stale-finding revalidation before applying the recommendation.
- [ ] **MAINT-OPT-052**: If revalidation fails, is unavailable, or is stale, then the system shall not queue the repair and shall surface the reason for manual action.
- [ ] **MAINT-OPT-053**: The system shall reserve and enforce the elected per-repair cost and time caps, preserving repair evidence when a cap is exhausted.
- [ ] **MAINT-OPT-054**: The system shall record every gate result, snapshot value, revalidation result, non-queue reason, and repair linkage as durable provenance.
- [ ] **MAINT-OPT-055**: When `maintenance_runs` is disabled after admission, the system shall stop new automatic queues without cancelling an admitted repair.
- [ ] **MAINT-OPT-056**: The system shall fail closed for automatic repair when structured assessment output is invalid, absent, or unavailable.
- [ ] **MAINT-OPT-057**: The system shall not allow automatic repair to widen the finding's approved symbols or scope.
- [ ] **MAINT-OPT-058**: The system shall make duplicate, stale, denied, and budget-blocked automatic-repair outcomes visible rather than silently retrying them.
- [ ] **MAINT-OPT-059**: The system shall test election, standing filtering, scope preservation, revalidation, idempotency, budget enforcement, and security exclusion before enabling the policy.
