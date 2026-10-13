# RDR-075 Closeout Audit — 2026-10-12

- **RDR**: [RDR-075: Layered Verification Add-On (Defense in Depth)](https://github.com/viamin/paid/pull/4364) (Draft, held for human review in PR #4364; not yet merged)
- **Closeout issue**: [#4370](https://github.com/viamin/paid/issues/4370) (open — kept open, see Closure decision)
- **Umbrella**: [#4365](https://github.com/viamin/paid/issues/4365) (open; this closeout `Tracks` it and does not close it)
- **Conclusion**: **Implementation closeout is not yet eligible. RDR-075 remains Draft.** None of the closeout checklist's terminal statuses is accurate: the RDR is neither implemented, partially implemented, superseded, nor abandoned. Its active, focused implementation work remains open in the four phase issues (#4366, #4367, #4368, #4369), each of which is itself an explicit dependency of this audit and carries the `planning` label reserved for issues whose plan still depends on upstream decisions (the `lid_planning` run that converts the RDR into LID artifacts at `docs/intent/layered-verification/`).

This audit follows the [RDR Closeout Checklist](closeout-checklist.md). It uses RDR-075's Decision, Rollout Guard, Implementation Plan, and Validation sections as the source of truth, then verifies them against the current codebase and a live test run — not against closed-issue history. The Phase 1–4 phase issues all carry the `planning` label and predate any implementation work, so they cannot be treated as evidence of shipped behavior.

## RDR status and umbrella state

| Artifact | State |
| --- | --- |
| `docs/rdrs/RDR-075-layered-verification-defense-in-depth.md` | **Not present in `main`.** The RDR text lives only in PR [#4364](https://github.com/viamin/paid/pull/4364), labeled `paid-hold-review` (held for human review). `docs/rdrs/README.md` therefore does not list RDR-075 on `main`; the row that PR #4364 adds is held behind the same review gate. This audit cannot update the RDR file itself until PR #4364 merges; it tracks the umbrella with `Tracks #4365` and uses non-closing language so the umbrella's own final audit remains reachable. |
| Umbrella epic [#4365](https://github.com/viamin/paid/issues/4365) | Open; labeled `epic`, `P1`. |
| Phase 1 issue [#4366](https://github.com/viamin/paid/issues/4366) | Open; labeled `planning`, `P1`. No code merged. |
| Phase 2 issue [#4367](https://github.com/viamin/paid/issues/4367) | Open; labeled `planning`, `P1`. No code merged. |
| Phase 3 issue [#4368](https://github.com/viamin/paid/issues/4368) | Open; labeled `planning`, `P1`. No code merged. |
| Phase 4 issue [#4369](https://github.com/viamin/paid/issues/4369) | Open; labeled `planning`, `P1`. No code merged. |
| Closeout issue [#4370](https://github.com/viamin/paid/issues/4370) (this audit) | Open; labeled `quality`, `P1`. None of the effective auto-pick skip labels (`planning`, `research`, `waiting`, `tracking`, `needs-manual-setup`) are present, so the audit is auto-pickable once this PR is opened. |
| `docs/intent/layered-verification/` (LID conversion target) | **Does not exist.** The umbrella explicitly defers `lid_planning` until after PR #4364 merges; the `@spec VERIFY-001`–`VERIFY-014` annotations the RDR advertises therefore have no artifact ids to reference yet. The phase issues mark their implementation blocks as `@spec TBD-RDR-075-Phase-N`. |

## Acceptance evidence

The RDR's Validation § Implementation acceptance criteria enumerate ten requirements (Acceptance 1–10). Each row below records the shipped state of that requirement as found in the audit environment, the file_path:line evidence (or its confirmed absence), and the focused open owner where one exists.

| Acceptance criterion | Result | Code/test evidence and remaining owner |
| --- | --- | --- |
| 1. `FeatureFlags::DEFINITIONS` entry `layered_verification_coordinator` defaults to off and toggles coordinator scheduling only | **Gap** | `app/services/feature_flags.rb:10-88` enumerates eleven definitions (`context_intake_agent_questions`, `managed_subscription_runner_auth`, `execution_runner_enabled`, `prompt_assembly`, `prompt_assembly_shadow_compare`, `runner_model_policy_form`, `intent_conformance_enforcement`, `intent_conformance_shadow_review`, `approved_intent_amendments`, `apple_verification_workers`, `marketplace_tool_sidecars`). `layered_verification_coordinator` is absent. Repo-wide search for `layered_verification_coordinator`, `Verification::Coordinator`, `Verification::LayerContract`, `BusinessObligation`, and `business_obligations` returns zero matches outside this audit and the PR-#4364-only RDR text. Focused owner: [#4366](https://github.com/viamin/paid/issues/4366) (`@spec VERIFY-001`). |
| 2. `BusinessObligation` persists with validations, lifecycle services, Pundit policy, and `KnowledgeArtifact` mirroring at `artifact_type: "business_obligation"` | **Gap** | No `BusinessObligation` model, `business_obligations` migration, or `BusinessObligationPolicy`. The knowledge-artifact mirror is the `ChangeIntent` precedent (`docs/rdrs/RDR-042-change-intent-records.md`); no `business_obligation` artifact_type value exists. Repo-wide search for `business_obligation` returns zero matches outside this audit and the PR-#4364-only RDR text. Focused owner: [#4366](https://github.com/viamin/paid/issues/4366) (`@spec VERIFY-002`). |
| 3. Each registered layer passes the `Verification::LayerContract` formal property tests at registration; structurally rejected layers cannot register | **Gap** | No `Verification::LayerContract` (`app/services/verification/layer_contract.rb`), no `app/services/verification/` directory, and no layer registration manifest. `Reviews::Verification::*` (`app/services/reviews/verification/`) is an unrelated PR-review pipeline that does not implement this contract. Focused owner: [#4366](https://github.com/viamin/paid/issues/4366) (`@spec VERIFY-003`). |
| 4. The coordinator reads the rubric and emits a verifier plan whose layer set varies materially across obligations whose six risk categories differ; structural test fails if the rubric returns an identical set for two such obligations | **Gap** | No `Verification::Coordinator` and no `Verification::Rubric`. The six brief-named risk categories (correctness, completeness, safety/security, performance, consistency/intent fidelity, provenance/reproducibility) are documented in the RDR text only. Focused owner: [#4367](https://github.com/viamin/paid/issues/4367) (`@spec VERIFY-006`). |
| 5. The coordinator runs an audit entry that produces an obligation-by-obligation coverage report; the report is content-stable across runs whose evidence has not changed | **Gap** | No coordinator, no audit entry, no coverage report rendering. The existing `Inbox::Queue` lane set (`app/services/inbox/queue.rb`) does not include a coverage or verification-finding lane. Focused owner: [#4367](https://github.com/viamin/paid/issues/4367) (`@spec VERIFY-005`) plus [#4368](https://github.com/viamin/paid/issues/4368) (`@spec VERIFY-011`) for the UI surface. |
| 6. When an obligation's intent is updated (claim hash changes), evidence keyed on the old claim is invalidated; evidence keyed on unrelated claims remains valid; the cost of the recompute is bounded by the obligation's evidence count, not the obligation graph size | **Gap** | No content-addressed evidence model; no obligation graph; no invalidation routine. The existing `ExecutionAuditEvent` append-only stream (`app/services/execution_audit_events/lifecycle.rb`) is in place as the substrate, but no verifier-scheduling, completion, or invalidation events extend it for this RDR. Focused owner: [#4367](https://github.com/viamin/paid/issues/4367) (`@spec VERIFY-007`, `VERIFY-008`). |
| 7. When an implementation commit changes only one product surface, evidence on unchanged surfaces remains valid; the cost of the recompute is bounded by the diff, not the obligation graph size | **Gap** | Same as Acceptance 6; the evidence model and invalidation routine do not exist. Focused owner: [#4367](https://github.com/viamin/paid/issues/4367) (`@spec VERIFY-008`). |
| 8. CI, security scanners, code review, branch protection, and conformance-with-approved-design run unchanged with the flag off, with the flag on, and with the flag on for one project and off for another on the same account; the flag affects only coordinator-scheduled verifiers | **Preserved invariant** (no new behavior required to honor it today) | Mandatory host policies are unaffected by the absence of the new flag and its coordinator. The host guards in scope today run unconditionally: `VerifyAtMerge` (`app/services/intent_conformance/verify_at_merge.rb`) sits behind its own `intent_conformance_enforcement` and `approved_intent_amendments` flags and is verified by `spec/services/intent_conformance/verify_at_merge_spec.rb`; CI/security/code review/branch protection live in `Gemfile`/`config/initializers/`/`.github/workflows/` outside this RDR's reach. **Disposition: the invariant is intact because nothing has been added that could violate it.** Focused owner: [#4366](https://github.com/viamin/paid/issues/4366) (`@spec VERIFY-004`). |
| 9. The bootstrap entry proposes obligations through chat, waits for human accept/edit/reject, and commits the resulting set via the docs-only PR path; autonomous minting is rejected by a structural test | **Gap** | No bootstrap chat flow, no obligation minting flow, no docs-only commitment path. `Lid::InjectIntoPrompt` (`app/services/lid/inject_into_prompt.rb`) and `Lid::PlanningContract` (`app/services/lid/planning_contract.rb`) exist as substrate, but the bootstrap entry that the RDR describes does not. Focused owner: [#4368](https://github.com/viamin/paid/issues/4368) (`@spec VERIFY-012`). |
| 10. The four-class finding synthesis distinguishes missing, stale, drifted, and failed evidence; a failed finding cannot be cleared by re-running the same layer with a different prompt; the Inbox filters and actions differ by class | **Gap** | No `Verification::Finding` typed lane; no `missing_evidence`, `stale_evidence`, `drifted_obligation`, or `failed_verification` Inbox items; no class-distinct actions. The closest existing typed lane is `Inbox::IntentConformance` (`app/services/inbox/intent_conformance.rb`), which is the RDR-067 conformance-guard precedent the obligation store is meant to delegate to, not the new finding taxonomy. Focused owner: [#4368](https://github.com/viamin/paid/issues/4368) (`@spec VERIFY-013`). |

The RDR's Validation § Test scenarios 1–8 (audit entry on a new obligation; rubric materially different layer sets; intent-update invalidation; commit invalidation; failed-finding handling; bootstrap human-in-the-loop; flag-off rollback; pilot adoption) likewise have no `file_path:line` evidence. Each one corresponds to behavior that lives only in the RDR text and the open phase issues.

The Validation § Reconsideration conditions (Paid-as-host vs. standalone; rubric materially different plans; incremental adoption around a coherent business slice; linkage-vs-conformance kept distinct) are explicitly Phase 4 work and have no Phase 4 record today. They cannot resolve until Phases 1–3 ship.

## Phases 1–4 status as of audit date

| Phase | Issue | Acceptance criteria count | `@spec` ids | Implementation status |
| --- | --- | --- | --- | --- |
| 1 — Host substrate, obligation store, layer contract | [#4366](https://github.com/viamin/paid/issues/4366) | 6 | `VERIFY-001`–`VERIFY-004` (annotated `@spec TBD-RDR-075-Phase-1` until `lid_planning` lands) | Not started; issue labeled `planning` |
| 2 — Coordinator, selection rubric, evidence model | [#4367](https://github.com/viamin/paid/issues/4367) | 6 | `VERIFY-005`–`VERIFY-008` (annotated `@spec TBD-RDR-075-Phase-2` until `lid_planning` lands) | Not started; issue labeled `planning` |
| 3 — Remaining layers, three entry paths, review package, finding synthesis | [#4368](https://github.com/viamin/paid/issues/4368) | 7 | `VERIFY-009`–`VERIFY-013` (annotated `@spec TBD-RDR-075-Phase-3` until `lid_planning` lands) | Not started; issue labeled `planning` |
| 4 — Evaluation, reconsideration conditions, gap closeout | [#4369](https://github.com/viamin/paid/issues/4369) | 5 | `VERIFY-014` (annotated `@spec TBD-RDR-075-Phase-4` until `lid_planning` lands) | Not started; issue labeled `planning` |

The umbrella's stated sequencing is Phase 1 → Phase 2 → Phase 3 → Phase 4 → Closeout. None of Phases 1–4 has produced a merged PR. The `@spec` ids in the table are the slots the umbrella reserves; the artifacts the `@spec` ids reference (`docs/intent/layered-verification/layered-verification-specs.md` and the EARS claims it contains) have not been written, so the implementing agents cannot yet adopt the ids. Each phase issue itself states this dependency: `@spec TBD-RDR-075-Phase-N` until `lid_planning` lands.

## Reused but insufficient foundations

The RDR's Context § Existing Paid host capabilities the add-on composes with names eight substrate pieces. Every one of them exists today and is unaffected by the absence of the new coordinator; none of them satisfies any RDR-075 acceptance criterion by itself:

- `AgentRun` and `Activities::RunAgentActivity` (`app/models/agent_run.rb`, `app/temporal/activities/run_agent_activity.rb`) — the agent-run goal surface. The new `audit` goal that the coordinator would use does not exist; the existing `AgentRun::GOALS` enumeration is unchanged.
- `Lid::InjectIntoPrompt`, `Lid::PlanningContract` (`app/services/lid/`) — repository-native design substrate. The bootstrap entry would compose with this; the new obligation contracts under `docs/intent/layered-verification/` do not exist.
- `FeatureIntent`, `DesignAmendments::EvaluateImpact`, `FeatureIntents::RunAdmission` (`app/models/feature_intent.rb`, `app/services/design_amendments/`, `app/services/feature_intents/`) — Feature Intent workflow. The new obligation records would reuse this; no obligation record exists.
- `KnowledgeArtifact`/`KnowledgeChunk`, `ChangeIntent` (`app/models/knowledge_artifact.rb`, `app/services/change_intents/`) — knowledge pipeline. `ChangeIntent` is the precedent for `artifact_type: "business_obligation"`, which is not added.
- `Tdd::Mode`, `Tdd::ReturnToTestReview` (`app/services/tdd/`, `docs/rdrs/RDR-056-strict-test-driven-development-mode.md`) — TDD modes. The `behavioral_test` layer would read this; no layer implementation exists.
- `Projects::Readiness` (`app/services/projects/readiness.rb`, `docs/rdrs/RDR-074-project-readiness.md`) — project readiness. Same: the layer would read it; no layer exists.
- `Inbox::Queue`, `Inbox::IntentConformance` (`app/services/inbox/queue.rb`, `app/services/inbox/intent_conformance.rb`) — Inbox surface. The four-class finding taxonomy is meant to extend this; the new typed lanes do not exist.
- `ExecutionAuditEvent`, `ExecutionAuditEvents::Lifecycle` (`app/models/execution_audit_event.rb`, `app/services/execution_audit_events/lifecycle.rb`) — audit-event substrate. Verifier-scheduling/completion/invalidation events would extend the same stream; no such extension is shipped.

Reusing them must preserve their existing behavior rather than recreate or relabel it as layered-verification behavior. None of the eight pieces is changed, gated, or shadowed by RDR-075 work today; that is the correct disposition given that no RDR-075 work exists yet.

## Rollout guard disposition

The RDR's Rollout Guard section requires a `layered_verification_coordinator` flag, default off, added to `FeatureFlags::DEFINITIONS` by the Phase 1 implementation issue, with a per-tenant opt-in enablement surface. That flag does not exist in `app/services/feature_flags.rb:10-88` today, and the runtime gate the rollout guard requires is not wired.

**Disposition: the guard is still required and remains pending**, owned by #4366 acceptance criterion 1. No coordinator or layer is shipped, so no runtime behavior bypasses or needs to bypass the guard. Mandatory host policies (CI, security, code review, branch protection, `IntentConformance::VerifyAtMerge`) continue to run unchanged because the new flag's absence means no coordinator scheduling can occur. Nothing in this audit should be read as license to expose obligation finding or coordinator scheduling without the guard.

## Required gaps and dependencies

No duplicate child issue was filed. Each unmet acceptance criterion already has one focused, open owner under the umbrella:

- [#4366](https://github.com/viamin/paid/issues/4366) (Phase 1) — host substrate, obligation store, layer contract, three deterministic layers (`linkage_freshness`, `behavioral_test`, `implementation_specification_conformance`); covers Acceptance 1, 2, 3, 8 of the RDR's ten validation criteria.
- [#4367](https://github.com/viamin/paid/issues/4367) (Phase 2) — coordinator, six-category rubric, content-addressed evidence model, targeted invalidation, programmatic `audit` entry; covers Acceptance 4, 5, 6, 7.
- [#4368](https://github.com/viamin/paid/issues/4368) (Phase 3) — six semantic layers, design/audit/bootstrap entry paths, business-facing review package, four-class finding synthesis; covers Acceptance 9, 10.
- [#4369](https://github.com/viamin/paid/issues/4369) (Phase 4) — ten acceptance demonstrations, four brief reconsideration conditions, evaluation report, gap filing; covers the RDR's `VERIFY-014` and the closeout-evidence preparation that feeds back into this audit.

The umbrella issue #4365 already explicitly depends on all four phases. This audit records no additional dependency that the umbrella did not already declare.

## Label hygiene

- This closeout issue (#4370) carries `quality` and `P1`. None of the effective auto-pick skip labels (`planning`, `research`, `waiting`, `tracking`, `needs-manual-setup`) are present, so the closeout is auto-pickable once this PR opens.
- The phase issues #4366, #4367, #4368, #4369 today carry the `planning` label, which the closeout checklist §6 reserves for issues that need human/LLM planning before any implementation. That reservation fits these issues: each is concrete implementation work whose plan still depends on `lid_planning` (the umbrella's own stated prerequisite for resolving `@spec VERIFY-###` ids) and on PR #4364's merge (so the RDR is the source of truth rather than a held-for-review draft). They will lose `planning` when the umbrella's `lid_planning` PR lands and an operator promotes each one to runnable status — a dependency-issue action, not a closeout-audit action.

## Verification

This audit's absence findings were confirmed by:

- Repo-wide search for `BusinessObligation`, `business_obligations`, `business_obligation`, `Verification::LayerContract`, `Verification::Coordinator`, `Verification::Rubric`, `Verification::Finding`, `layered_verification_coordinator`, `layered_verification`, and `Inbox::VerificationFinding` — zero matches outside this audit and the PR-#4364-only RDR text.
- Repo-wide search for `docs/intent/layered-verification/` — directory does not exist (the closest existing segment names are listed in `docs/intent/`; the new segment is absent).
- Reading `app/services/feature_flags.rb:10-88` end-to-end to confirm `layered_verification_coordinator` is absent from `FeatureFlags::DEFINITIONS`.
- Reading `db/schema.rb` (canonical schema reference) to confirm no `business_obligations` table exists; the closest related tables (`feature_intents`, `design_amendments`, `change_intents`) are unrelated RDR scope.
- Running `bin/coherence-check.mjs` in this audit environment — see "Verification run" below.

### Verification run

The audit's evidence-confirmation checks were run in the isolated test environment. The audit does not run any RDR-075-specific specs because no RDR-075 specs exist; the closest existing specs that would catch a regression in the substrate pieces the RDR composes with were exercised to confirm this audit does not regress shipped behavior:

```text
RAILS_ENV=test bundle exec rspec \
  spec/services/projects/readiness_spec.rb \
  spec/services/feature_intents/run_admission_spec.rb \
  spec/services/intent_conformance/verify_at_merge_spec.rb \
  spec/services/design_amendments/evaluate_impact_spec.rb \
  spec/services/inbox/queue_spec.rb \
  spec/models/feature_intent_spec.rb
```

Result: existing foundation examples passed (2026-10-12). They prove the substrate behavior described above; they do not supply false evidence for the unimplemented RDR-075 acceptance criteria.

`bin/coherence-check.mjs` completed with the expected RDR-075 absence (no `docs/intent/layered-verification/` segment, no `@spec VERIFY-###` annotations, no arrow references to RDR-075 from the EARS tree). The check reported no arrow-reference errors for existing segments.

`bin/rubocop` was run on the files this audit adds and found no offenses. `bundle exec rspec` on the verification suite above passed.

`bin/rails db:prepare` was attempted as required. The audit environment's PostgreSQL service is reachable; the audit uses the provided `DATABASE_URL` (`postgres://agent:agent@paid-svc-a3-s1-postgres:5432/agent_run_11939_attempt_0`) for the verification suite only. No destructive database operation was attempted. The audit must not report database-backed validation of RDR-075 behavior as passing because no such behavior exists; the verification run only confirms that documenting the current status does not regress shipped substrate.

## Stale status reconciled by this audit

- `docs/rdrs/RDR-075-layered-verification-defense-in-depth.md`: does not exist on `main`. PR #4364 carries the Draft text under `paid-hold-review`; that PR is the only place the RDR text lives. This audit cannot flip the RDR's Status metadata until PR #4364 merges and the file is on `main`.
- `docs/rdrs/README.md`: no RDR-075 row exists on `main` because PR #4364 adds it as part of the held-for-review Draft. This audit does not duplicate that row to avoid conflicting with PR #4364; the README index row is owned by the RDR's own PR and will land with it.
- `docs/intent/layered-verification/`: does not exist. The `lid_planning` run that creates it is the umbrella's stated prerequisite for resolving the `@spec VERIFY-###` ids. No EARS claims to reconcile; no `[ ]`/`[x]`/ `[D]` status markers to update.
- `docs/arrows/index.yaml`: no RDR-075 segment is registered. The segment will be added by the `lid_planning` run, not by this audit.

## Closure decision and prerequisites

Do **not** close #4370. Required gaps remain across all ten acceptance criteria and map to the four open phase issues already filed under the umbrella. This audit adds no new dependency that the umbrella did not already declare; it explicitly tracks #4365 with `Tracks #4365` non-closing language and is non-closing itself, because:

- The umbrella's final acceptance audit (a future closeout run after all four phase issues have shipped) is the only place that may close #4365 with `Closes #4365`. Per the closeout checklist §8, only the final umbrella audit may visibly close the umbrella, and only when its evidence confirms no required gaps remain.
- This audit's purpose is to record the current state honestly, not to claim closure prematurely. The audit's closeout PR carries the `paid-hold-review` label so a human reviewer can decide whether to land the audit now (as the early "not yet eligible" record) or to defer until PR #4364 merges and the phase issues begin shipping.

The PR description must say `Tracks #4365` and `Tracks #4370`, not `Closes` for either issue. #4370 remains open until the four phase issues (#4366–#4369) land and a follow-up audit re-verifies the ten acceptance criteria. #4365 remains open until its children resolve and a final umbrella acceptance audit is filed. The `epic` label on #4365 identifies the umbrella, which receives a final acceptance audit once its children resolve, and does not silently exclude the issue from auto-pick.

When PR #4364 merges and Phases 1–4 begin producing merged PRs, this audit must be re-run: re-walk the per-acceptance check above, add EARS claims to `docs/intent/layered-verification/` alongside the code, confirm `bin/coherence-check.mjs` is clean for the new segment, and only then flip the RDR and README index row to **Partially Implemented** (and later **Implemented** when every acceptance criterion has shipped code and test evidence).

## Notes

- The `@spec TBD-RDR-075-Phase-N` markers in the four phase issues are deliberate. They advertise the `VERIFY-###` ids the RDR reserves without pretending those ids have an artifact to point at; they will be replaced once `lid_planning` materializes the EARS claims under `docs/intent/layered-verification/layered-verification-specs.md`.
- The four brief-supplied risk categories (correctness, completeness, safety/security, performance, consistency/intent fidelity, provenance/reproducibility) and the nine brief-supplied layer kinds (`business_process_formalization`, `verification_planning`, `engineering_translation`, `linkage_freshness`, `behavioral_test`, `formal_verification`, `mutation`, `implementation_specification_conformance`, `independent_semantic_audit`) are preserved verbatim by the phase issues; this audit does not rename them.
- The audit uses GitHub-visible evidence (`file_path:line` for what exists; explicit absence statements for what does not) rather than prose conclusions. A future re-run that finds Phase 1 merged PRs can replace each "Gap" row above with concrete `file_path:line` evidence the way the RDR-069 / RDR-071 / RDR-072 audits do.
