# RDR-075 General Maintenance Runs — Blocked Closeout Audit — 2026-10-23

- **Draft design:** [PR #4308](https://github.com/viamin/paid/pull/4308) (open, unmerged)
- **Tracks:** [#4334](https://github.com/viamin/paid/issues/4334), which remains
  open to own the final cross-recipe evaluation and guard-removal decision
- **Dependency:** [#4333](https://github.com/viamin/paid/issues/4333) (M06) must
  ship before that final evaluation can run
- **Tracks:** [#4326](https://github.com/viamin/paid/issues/4326) — only the
  umbrella's own final acceptance audit may close it
- **Status decision:** **Blocked.** No RDR-075 runtime behavior is shipped, so
  no implementation status may be asserted and the `maintenance_runs` guard
  cannot be removed.
- **Supersedes as current readiness evidence:** the 2026-10-15 C75 audit
  ([`audit-report-2026-10-15-rdr-075.md`](audit-report-2026-10-15-rdr-075.md)).
  Earlier RDR-075 artifacts (2026-10-12, 2026-10-13, 2026-10-14) remain
  historical records.

This is a fresh source-and-state inspection, not an inference from child-issue
closure. It follows the
[RDR closeout checklist](closeout-checklist.md). One material fact changed since
2026-10-15: the RDR-073 prerequisite is now satisfied. That removes one former
blocker and does not move RDR-075 out of **Blocked**.

## What changed since the 2026-10-15 audit

| Item | 2026-10-15 | 2026-10-23 | Effect |
| --- | --- | --- | --- |
| RDR-073 umbrella #4263 | Open | **Closed** | The prerequisite named in the draft's Dependencies section and in this issue ("Depends on viamin/paid#4263, including RDR-073 closeout #4268 and final acceptance") is satisfied. |
| RDR-073 final acceptance | Outstanding | Shipped per [`audit-report-2026-10-20-rdr-073-epic-final-acceptance.md`](audit-report-2026-10-20-rdr-073-epic-final-acceptance.md); all four delivery phases verified against RDR-073's validation criteria | Tool-substrate availability is established; `marketplace_tool_sidecars` stays default-off and separately authoritative. |
| Critical assumption 2 (checkout access / batch invocation) | Unvalidated | Still owned by #4327, open | Implementation still may not proceed past planning. |
| Design PR #4308 | Open, unmerged | Open, unmerged | RDR-075 is still Draft and still not repository authority. |
| M00–M06 #4327–#4333 | Open | Open, all labelled `planning` | No phase has shipped. |
| Intent-traceability recipe #4340 | Open | Open, `planning` | The required report-only recipe has not shipped. |
| Umbrella #4326 | Closed (2026-10-15T00:46:01Z), flagged as inconsistent | Still closed | Still inconsistent with the draft's "only the umbrella's own final acceptance may close it" rule; reopening is an operator action. |

The 2026-10-15 audit's substantive conclusions all still hold. Only the RDR-073
row changed.

## Live dependency state (2026-10-23)

| Requirement | State | Consequence |
| --- | --- | --- |
| Design PR #4308 | Open, unmerged | Draft design; no approved maintenance LLD/EARS exists. |
| RDR-073 umbrella #4263, closeout #4268, final acceptance | Closed / closed / shipped | Prerequisite satisfied; RDR-073's own guard remains authoritative for tool admission. |
| M00 planning + tool handoff #4327 | Open, `planning` | Critical assumption 2 unvalidated; LID artifacts not created. |
| M01–M06 #4328–#4333 | Open, all `planning` | No delivery phase has shipped or started. |
| C75 closeout #4334 (this issue) | Open, labels `quality`, `P2` | Carries none of the effective auto-pick skip labels. |
| Intent-traceability recipe #4340 | Open, `planning` | Report-only recipe coverage absent. |
| Shared reconciliation substrate #4339 | Closed | Substrate shipped and reusable; the maintenance recipe that must reuse it is still unimplemented. |

## Shipped-surface inspection (2026-10-23)

No repository authority or runtime surface satisfies an RDR-075 criterion:

- `docs/rdrs/RDR-075-general-maintenance-runs.md` does not exist in this
  checkout; the design is present only in PR #4308 (380 added lines there). No
  `docs/intent/` maintenance segment exists, so there are no approved
  `@spec` claims to link tests to.
- [`app/models/agent_run.rb:34`](../../app/models/agent_run.rb#L34) declares
  `GOALS = %w[create_pr create_issue review enhance_issue analyze_issue
  lid_planning create_feature bootstrap_readiness]`; goal inclusion validation at
  [`app/models/agent_run.rb:286`](../../app/models/agent_run.rb#L286) accepts no
  maintenance goal.
  [`spec/models/agent_run_spec.rb:65`](../../spec/models/agent_run_spec.rb#L65)
  and `spec/models/agent_run_spec.rb:4764` assert that closed goal set — an
  absence test, not maintenance lifecycle evidence.
- [`app/services/feature_flags.rb:10`](../../app/services/feature_flags.rb#L10)
  defines twelve flags and **no `maintenance_runs` key**. RDR-073's tool guard is
  separately defined at
  [`app/services/feature_flags.rb:88`](../../app/services/feature_flags.rb#L88)
  and read at
  [`app/services/containers/mcp_provisioner.rb:320`](../../app/services/containers/mcp_provisioner.rb#L320).
  A repository-wide search for `marketplace_tool_sidecars` finds only that flag
  definition and that single provisioning check, plus two spec references — there
  is no maintenance consumer of the tool lifecycle.
- [`app/mcp/tools/trigger_agent_run.rb:31`](../../app/mcp/tools/trigger_agent_run.rb#L31)
  constrains `goal` to `AgentRun::GOALS`, so the MCP surface has no maintenance
  entry point. The manual `custom_prompt` path the draft cites as existing
  capability is at
  [`app/controllers/projects/agent_runs_controller.rb:156`](../../app/controllers/projects/agent_runs_controller.rb#L156)-`222`.
- Repository-wide search on 2026-10-23: **zero** occurrences of
  `maintenance_runs`, `MaintenanceRun`, or `maintenance_run`. The 166 remaining
  matches of the bare word across 160 matching lines in `app/`, `lib/`, `config/`,
  `db/`, and `spec/` are
  pre-existing unrelated vocabulary — the GoodJob `maintenance` queue
  ([`config/initializers/good_job.rb:17`](../../config/initializers/good_job.rb#L17)),
  `maintenance_window` / `maintenance_timezone` at
  [`app/controllers/accounts/compliance_dashboards_controller.rb:101`](../../app/controllers/accounts/compliance_dashboards_controller.rb#L101),
  and the distinct mutation sweep at
  [`app/jobs/scheduled_mutation_sweep_job.rb:3`](../../app/jobs/scheduled_mutation_sweep_job.rb#L3).
- `db/schema.rb` contains no maintenance report, evidence, finding, coverage,
  schedule, or advisory-audit table; no model, service, controller, view, job,
  MCP tool, or spec implements any of them.

### Substrate that does ship

The intent-traceability criterion depends on shared reconciliation capability
that genuinely exists, and it must be reused rather than rebuilt:

- [`app/services/feature_intents/reconcile_design_artifacts.rb`](../../app/services/feature_intents/reconcile_design_artifacts.rb)
  (`@spec DESIGN-RECONCILIATION-001`, claimed at
  [`docs/intent/feature-approval/feature-approval-specs.md:202`](../../docs/intent/feature-approval/feature-approval-specs.md#L202))
  distinguishes missing tree, partial tree, present-but-unlinked/stale
  metadata, deliberate deferral, and unverifiable coverage.
- [`app/services/feature_intents/discover_rdr_artifacts.rb`](../../app/services/feature_intents/discover_rdr_artifacts.rb)
  (`docs/rdrs`, `RDR-*.md`, repository-configurable convention).
- `DesignArtifactFindings::FileIssue` and
  `DesignArtifactFindings::RepairDocumentLinks` provide bounded, authorized
  repair handoffs.

No maintenance recipe wraps this substrate: there is no maintenance goal,
recipe registration, report contract, or guard, so the required closeout
coverage in the "Intent-traceability maintenance coverage" section of this
issue is **not** satisfied by the substrate alone.

## Acceptance-criterion audit

Draft validation scenarios are quoted from PR #4308's `## Validation` section.
"Result" reflects shipped code and tests, never issue state.

| # | Draft criterion (abridged) | Code and test evidence | Result | Owning work |
| --- | --- | --- | --- | --- |
| 1–2 | Issue-less manual A/B scan resolves targets, retains guidance, inspects supporting callers, stays in scope; ambiguous targets clarify instead of broadening; broad audit records broad scope | No maintenance goal, objective/scope/guidance snapshot, clarification outcome, UI/API/MCP admission, or behavior spec exists. `custom_prompt` runs are issue-backed PR/issue goals, not report-only investigations. | Not implemented | #4328 |
| 3 | Independent workflows and dynamically invoked framework code are not recommended from analyzer output alone | No maintenance analyzer, candidate assessment, or counterevidence surface. | Not implemented | #4330 |
| 4 | Supported tool attaches through RDR-073, analyzes the pinned checkout in isolation, records version/config evidence; issue-less polyglot selection works without issue labels | RDR-073's guarded arm exists (`mcp_provisioner.rb:320`, 29 passing examples in its spec today) but no maintenance adapter consumes it, pins a checkout, or records provenance; Critical assumption 2 is still #4327's open question. | Not implemented (substrate available) | #4327, #4330 |
| 5 | Clean scan succeeds; parse error, missing tool, timeout, or budget exhaustion yields visible incomplete coverage and never a false clean; source preserved | No report, evidence, coverage-state, or terminal-outcome model/spec exists. | Not implemented | #4328, #4329 |
| 6 | Repeat scans update occurrences without duplicate repair work; changed evidence prompts dismissed-finding reassessment | No finding identity, occurrence, or dismissal surface exists. | Not implemented | #4329, #4331 |
| 7 | Selected findings create bounded repair work linked to the report; changed revision requires revalidation | No selection, repair handoff, or revision revalidation surface exists. `DesignArtifactFindings::FileIssue` is the analogous non-maintenance handoff only. | Not implemented | #4331 |
| 8 | Recurring runs obey tenant access, budgets, non-overlap, bounded catchup; disabling stops dispatch and preserves reports | No maintenance schedule, dispatch, or budget surface exists. `ScheduledMutationSweepJob` is a distinct Ruby-only sweep and is not equivalent evidence. | Not implemented | #4332 |
| 9 | UI and API/MCP users start, inspect, cancel, and select repair work with equivalent authorization; maintenance not admitted while its guard is off | `AgentRun::GOALS` and the MCP goal enum admit no maintenance goal, and no maintenance admission path exists for the guard to close. | Not implemented | #4328, #4332 |
| 10 | PR audits separate new regressions from existing debt and publish through the existing review path without duplicate or stale-head findings | No maintenance evidence reuse or advisory PR-audit path exists. | Not implemented | #4333 |
| — | Evaluate on projects beyond Paid: actionable findings, false positives, unresolved coverage, latency, token/tool cost, repeated-finding noise, repair review outcomes | No admitted capability exists to evaluate; no corpus or measured results are stored. The draft itself states these measurements guide recipe selection and do not gate the capability. | Not implemented (measurable only after #4328–#4333) | #4327 recipe selection, #4340 recipe evaluation, and open #4334 after its #4333 dependency ships |
| — | Decide `maintenance_runs` guard removal from evidence; recurring schedules stay opt-in | `maintenance_runs` is not registered (see above); RDR-073's `marketplace_tool_sidecars` guard is untouched and still default-off. | **Retain** default-off; removal unsupported by evidence | #4328 registers it; open #4334 decides after #4333 ships |
| — | Intent-traceability recipe coverage (see next section) | Recipe absent; the shared reconciliation substrate it must reuse ships (see above). | Not implemented | #4340 |

No test can be cited as passing an RDR-075 behavior: neither approved EARS
claims nor implementation tests exist. RDR-073's tool-arm specs and
`FeatureFlags` specs must not be relabelled as maintenance evidence, and neither
may `FeatureIntents::ReconcileDesignArtifacts`'s own reconciliation specs.

## Intent-traceability maintenance coverage

This issue requires the final closeout to cover the recipe defined in #4340.
Assessed against shipped code, all seven facets are absent as *maintenance*
behavior; the underlying reconciliation substrate exists for four of them and
must be reused.

| Required facet | Shipped maintenance behavior | Reusable substrate | Owner |
| --- | --- | --- | --- |
| Existing-but-unlinked trees | None | `ReconcileDesignArtifacts` present-but-unlinked/stale-metadata state | #4340 |
| Missing phases | None | Phase/closeout coverage claims live in `docs/intent/`; no maintenance verifier consumes them | #4340 |
| Stale metadata preserved | None | `stale_metadata` / `stale_metadata_evidence` and the deferred-adoption path | #4340 |
| Shared / cross-project ownership | None | Explicit-identity matching only; semantic ownership assessment is deliberately left to `agent_harness` | #4340 |
| False positives | None measured | `coverage_complete?` and unverifiable-state handling | #4340 (measurement obligation) |
| Partial remote coverage | None | `coverage_complete:` input distinguishes partial from absent reads | #4340 |
| Report-only repair handoff | No maintenance handoff | `DesignArtifactFindings::FileIssue` / `RepairDocumentLinks` authorized repair path | #4340 |

The recipe issue's own criteria already require non-duplication of the RDR inventory,
scheduler, issue catalog, and verifier, plus evaluation beyond Paid and
preservation of the `maintenance_runs` default-off tenant rollout plus RDR-073's
separate tool policy. Its dependencies are satisfied except #4329 and the design
itself: #4339 (shared inventory/reconciliation and structural verifier) is closed
and its code is present. Nothing in this audit duplicates that work, and no
maintenance recipe behavior is claimed on its behalf.

## Gap ownership

Every unmet criterion above maps to an already-filed focused issue:
[#4328](https://github.com/viamin/paid/issues/4328),
[#4329](https://github.com/viamin/paid/issues/4329),
[#4330](https://github.com/viamin/paid/issues/4330),
[#4331](https://github.com/viamin/paid/issues/4331),
[#4332](https://github.com/viamin/paid/issues/4332), and
[#4333](https://github.com/viamin/paid/issues/4333) for the six delivery
phases; [#4327](https://github.com/viamin/paid/issues/4327) for LID planning and
the RDR-073 handoff validation; #4340 for the report-only
intent-traceability recipe; and open #4334, after its #4333 dependency ships,
for the cross-recipe external-project corpus and guard-removal decision. Verified against the
live issue bodies today, including the sub-criteria that the epic text names
only implicitly:

- timezone/next occurrence, overlap prevention, bounded catchup, budgets,
  disable/cancel, and UI/API/tool parity are explicit in
  [#4332](https://github.com/viamin/paid/issues/4332);
- version/configuration provenance and issue-label-optional polyglot matching are
  explicit in [#4330](https://github.com/viamin/paid/issues/4330);
- coverage disclosure for parse errors, missing tools, truncation, cancellation,
  and budget exhaustion is explicit in
  [#4329](https://github.com/viamin/paid/issues/4329);
- bounded repair selection and revision revalidation are explicit in
  [#4331](https://github.com/viamin/paid/issues/4331).

**No new gap issue is filed by this audit, and none is warranted:** filing a
duplicate would break the checklist's re-filing anti-pattern. Open #4334 retains
ownership of the cross-recipe external-project measurement and guard-removal
decision, but cannot complete either until its explicit #4333 dependency and the
other delivery phases ship. The gaps themselves remain open, not filed.

Label hygiene: #4334 carries `quality` and `P2` only — none of the effective
auto-pick skip labels (`planning`, `research`, `waiting`, `tracking`,
`needs-manual-setup`). #4327–#4333 and #4340 retain `planning` correctly, because
the design is unmerged and each needs planning plus LID artifacts before any
implementation; those labels were not removed by this audit, and no
`epic`-label override exists to reconcile.

## Validation evidence (2026-10-23)

- `bundle exec rubocop`: **4,072 files inspected, no offenses detected**.
- `node bin/coherence-check.mjs`: exits 0; arrow references are valid
  ("Arrows in index: 80", "All arrow references valid"). Its pre-existing reverse
  orphans, uncovered `[ ]` gap markers, and staleness signals are unrelated to
  this unimplemented RDR-075 segment.
- `bundle exec rspec spec/models/agent_run_spec.rb spec/services/feature_flags_spec.rb
  spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb
  spec/services/feature_intents/reconcile_design_artifacts_spec.rb`:
  **720 examples, 0 failures** — the run-goal, flag-registry, RDR-073 tool-arm,
  and design-reconciliation surfaces cited above (29 of those examples are the
  RDR-073 tool-arm spec).
- Repository-wide source inspection on 2026-10-23: zero `maintenance_runs`,
  `MaintenanceRun`, or `maintenance_run` identifiers; no maintenance intent
  segment; no maintenance schema, model, service, controller, view, job, MCP
  tool, or spec.

None of these results is presented as maintenance behavior evidence; they
establish only that this documentation change leaves the tree clean and that the
substrate cited above is real and passing.

## Conclusion, guard disposition, and rerun condition

**Closeout conclusion: Blocked.** RDR-075 remains an unmerged Draft, so it is not
repository authority and cannot truthfully receive an implementation status; and
no phase has shipped, so none of its acceptance criteria has evidence to audit.
This is not a claim of partial delivery and not a claim of abandonment — the
implementation tree is intact, unstarted, and correctly held.

**Rollout-guard disposition: retain.** Keep `maintenance_runs` default-off with
tenant opt-in through `tenant_settings.features` when #4328 registers it, read
through `FeatureFlags.enabled?(:maintenance_runs, project:)`. It is deliberately
not registered by this audit: registration belongs to #4328's implementation, and
adding a definition for behavior that does not exist would create dead rollout
configuration and an unowned flag. Recurring schedules must stay explicitly
opt-in even after a future guard decision. RDR-073's `marketplace_tool_sidecars`
guard remains separately authoritative and unchanged; this audit neither enables
nor weakens it.

**Umbrella:** unchanged. Use `Tracks #4326` language; #4326 remains closed at
2026-10-15T00:46:01Z, which is inconsistent with the draft's own rule, and
reopening it is an operator action this audit records but does not perform. Only
the umbrella's final acceptance audit may close it, and only when no required
gaps remain.

**Rerun condition.** Re-audit once: (1) PR #4308 merges and the HLD, maintenance
LLD/EARS and arrow references become repository authority through #4327;
(2) RDR-073 handoff validation (Critical assumption 2) resolves; (3) the six
delivery phases ship behind the default-off guard with failing-first,
`@spec`-annotated behavior tests; and (4) real external-project measurements are
recorded. That rerun must cite concrete code paths and passing test evidence for
every row above and then decide guard removal. Closure of child issues alone is
not sufficient evidence.
