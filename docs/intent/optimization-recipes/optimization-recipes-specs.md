# EARS: Maintenance Optimization Recipes

> **Draft — pending owner acceptance and merge.** All claims are active gaps.
> They describe no shipped behavior and do not authorize implementation,
> rollout, or automatic repair. They trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md).

## Catalog and Selection — #4493

- [ ] **MAINT-OPT-001**: The system shall define a versioned, code-owned optimization recipe catalog with a stable key, type, display name, and recipe version for every selectable recipe.
- [ ] **MAINT-OPT-002**: When a user selects a catalog recipe, the system shall reject an unknown, disabled, or structurally invalid key rather than infer a recipe from free text.
- [ ] **MAINT-OPT-003**: The system shall persist the selected recipe key and version on the maintenance run before evidence collection begins.
- [ ] **MAINT-OPT-004**: The system shall expose the same catalog entries and project-scoped selection authorization through UI, API, and MCP run-start surfaces.
- [ ] **MAINT-OPT-005**: The system shall treat a catalog entry as evidence-collection guidance and shall not treat selection as repair authorization.
- [ ] **MAINT-OPT-006**: When a run uses a natural-language target, the system shall record that target as requested scope and require clarification rather than silently broadening an ambiguous target.
- [ ] **MAINT-OPT-007**: The system shall preserve the requested scope as the bound on recommendations while permitting cited supporting inspection outside that scope.
- [ ] **MAINT-OPT-008**: When a recommendation needs changes outside the requested scope, the system shall identify that expansion and require explicit authorization before repair.
- [ ] **MAINT-OPT-009**: The system shall record each recipe's evidence collectors, limitations, and provenance in the resulting report.
- [ ] **MAINT-OPT-010**: The system shall not select a recipe by matching issue text, title keywords, or raw analyzer output.

## Initial Recipes and Honest Evidence — #4494

- [ ] **MAINT-OPT-020**: The system shall define Unnecessary Code, Duplication, Complexity, and Obsolete Behavior as the initial optimization recipe types.
- [ ] **MAINT-OPT-021**: The system shall record supporting evidence, known counterevidence, coverage limitations, proposed action, and validation plan for every optimization recommendation.
- [ ] **MAINT-OPT-022**: The system shall retain raw analyzer output as provenance and shall not treat it alone as proof that code is unused, safe to delete, or safe to consolidate.
- [ ] **MAINT-OPT-023**: When framework callbacks, reflection, external APIs, compatibility obligations, or intentional independence are relevant, the system shall include their consideration in the semantic assessment.
- [ ] **MAINT-OPT-024**: When a planned collector is unavailable, incomplete, cancelled, or budget-exhausted, the system shall preserve the corresponding RDR-075 incomplete report outcome and coverage limitation.
- [ ] **MAINT-OPT-025**: The system shall not present incomplete evidence as a clean or completed basis for an optimization recommendation.
- [ ] **MAINT-OPT-026**: The system shall resolve analyzer applicability per relevant package or ecosystem and shall not generalize one tool's output across unrelated repository components.
- [ ] **MAINT-OPT-027**: The system shall use `agent_harness` for semantic evaluation of candidate evidence and shall keep collector execution and structural parsing in the isolated execution boundary.

## Bounded Auto-Queue — #4495

- [ ] **MAINT-OPT-040**: The system shall obtain repair eligibility from an `agent_harness` structured assessment containing an ordered standing, rationale, citations, counterevidence, and a bounded proposed action.
- [ ] **MAINT-OPT-041**: The system shall accept only `supported`, `marginal`, `unsupported`, or `unknown` as repair-eligibility standings, and shall treat missing, malformed, or stale assessments as `unknown`.
- [ ] **MAINT-OPT-042**: The system shall not interpret an eligibility standing as a calibrated probability or aggregate it numerically with raw tool-confidence scores.
- [ ] **MAINT-OPT-043**: The system shall use raw tool-confidence only as report evidence and never as an automatic-repair authorization input.
- [ ] **MAINT-OPT-044**: The system shall offer a per-run, default-off auto-queue election with a minimum eligibility standing and explicit per-repair cost/time caps through UI, API, and MCP surfaces with equivalent authorization.
- [ ] **MAINT-OPT-045**: When the auto-queue election is omitted, the system shall preserve report-only behavior and shall not create repair work automatically.
- [ ] **MAINT-OPT-046**: The system shall deliver the full report regardless of whether any finding qualifies for auto-queue.
- [ ] **MAINT-OPT-047**: The system shall apply deterministic authorization, `maintenance_runs` guard, catalog posture, election, report status, standing, scope, budget, revalidation, and idempotency gates before dispatching an automatic repair.
- [ ] **MAINT-OPT-048**: When a report outcome is not `completed`, the system shall not auto-queue a repair and shall record the blocking outcome visibly.
- [ ] **MAINT-OPT-049**: The system shall create a qualifying automatic repair through the existing authorized M04 issue or PR-creation pathway with source report and canonical finding provenance.
- [ ] **MAINT-OPT-050**: The system shall apply the recorded explicit cost/time caps to each auto-queued repair run and preserve collected evidence when a cap is exhausted.
- [ ] **MAINT-OPT-051**: When the repair target revision has changed since the finding occurrence, the system shall require revalidation before applying the recommendation and shall surface failed or unavailable revalidation without silently dispatching a change.
- [ ] **MAINT-OPT-052**: The system shall restrict an auto-queued repair to the approved finding action and require explicit human authorization for broader scope.
- [ ] **MAINT-OPT-053**: The system shall use the canonical finding identity as the auto-queue idempotency key and shall not create duplicate repair work for repeated occurrences.

## Staged Types and Default-Deny Posture — #4496

- [ ] **MAINT-OPT-060**: The system shall assign every catalog type a repair posture of `auto_eligible`, `manual_only`, or `default_deny`.
- [ ] **MAINT-OPT-061**: The system shall keep Security Hardening `manual_only` and shall not allow a run-start election to widen that posture until separately authorized.
- [ ] **MAINT-OPT-062**: The system shall keep Cost Optimization, Design and Architecture, and Test Coverage `default_deny` until separate owner authorization supported by evaluation evidence changes their posture.
- [ ] **MAINT-OPT-063**: The system shall not permit a schedule, tenant setting, or recipe default to create an auto-queue election; only an authorized manual run-start election may narrow an already eligible posture.
