# RDR-075 General Maintenance Runs — Closeout Audit — 2026-10-15

- **Draft design:** [PR #4308](https://github.com/viamin/paid/pull/4308)
- **Closeout:** [#4334](https://github.com/viamin/paid/issues/4334)
- **Tracks:** [#4326](https://github.com/viamin/paid/issues/4326) (the
  umbrella's own final audit is the only authorized closer)
- **Decision:** **Partially Implemented — planning only.** No RDR-075 runtime
  behavior is shipped. The design remains Draft and is not repository
  authority, so this closeout cannot promote the RDR or remove its rollout
  guard.

This is an evidence audit, not an inference from child-issue state. It
supersedes the 2026-10-14 readiness snapshot for C75's current closeout
evidence. The audit uses the draft RDR in PR #4308 as the proposed contract;
it does not treat that unmerged document as permission to implement it.

## Admission and dependency state

The GitHub API was checked on 2026-10-15:

| Requirement | State | Consequence |
| --- | --- | --- |
| PR #4308 (RDR-075 design) | Open and unmerged | The RDR remains Draft; no approved maintenance LLD/EARS exists. |
| RDR-073 umbrella #4263 | Open | The separately authoritative tool-lifecycle dependency remains incomplete. |
| RDR-073 closeout #4268 | Closed | A closed closeout alone does not satisfy the required umbrella final acceptance. |
| M00–M06 #4327–#4333 | Open | All planned implementation phases remain unshipped. |
| Intent-traceability recipe #4340 | Open | The required report-only recipe and its stated closeout coverage are absent. |
| C75 #4334 | Open, `quality` label only | It carries none of the effective default auto-pick skip labels. |

The API also reports umbrella #4326 as closed at `2026-10-15T00:46:01Z`.
That is inconsistent with the draft's explicit rule that only the umbrella's
own final acceptance may close it, and with this audit's evidence. This
repository change does not mutate GitHub state; the umbrella needs reopening
before its final acceptance can be truthfully completed. This report uses
non-closing `Tracks #4326` language throughout.

## Shipped-surface inspection

No repository authority or runtime surface satisfies an RDR-075 criterion:

- `docs/rdrs/RDR-075-general-maintenance-runs.md` and a corresponding
  `docs/intent/` segment do not exist in this checkout. The design is present
  only in PR #4308, and therefore no approved EARS IDs can be linked to tests.
- [`app/models/agent_run.rb:33`](../../app/models/agent_run.rb#L33) has no
  maintenance goal, while its inclusion validation at
  [`app/models/agent_run.rb:285`](../../app/models/agent_run.rb#L285) excludes
  one. [`spec/models/agent_run_spec.rb:65`](../../spec/models/agent_run_spec.rb#L65)
  verifies that existing closed goal set, not a maintenance lifecycle.
- [`app/services/feature_flags.rb:10`](../../app/services/feature_flags.rb#L10)
  contains no `maintenance_runs` definition or admission check. The existing
  RDR-073 guard remains independently implemented as
  `marketplace_tool_sidecars` at
  [`app/services/feature_flags.rb:81`](../../app/services/feature_flags.rb#L81)
  and is consumed by
  [`app/services/containers/mcp_provisioner.rb:307`](../../app/services/containers/mcp_provisioner.rb#L307).
- The schema, models, services, controllers, MCP tools, jobs, views, and specs
  contain no maintenance report, evidence artifact, finding identity,
  recurrence/dismissal, repair handoff, schedule, or advisory PR-audit
  implementation. The only related shipped job is the distinct mutation sweep
  at [`app/jobs/scheduled_mutation_sweep_job.rb:3`](../../app/jobs/scheduled_mutation_sweep_job.rb#L3).

## Acceptance-criterion audit

| Draft criterion | Code and test evidence | Result | Focused required work |
| --- | --- | --- | --- |
| Manual issue-less A/B investigation, scoped guidance, supporting inspection, and no silent scope broadening | No maintenance goal, report contract, UI/API/MCP admission, or behavior spec exists. | Not implemented | #4328 |
| Broad/clean/partial/cancelled/budget-exhausted reports with preserved source and accurate coverage | No report, evidence, coverage, or terminal-outcome model/spec exists. | Not implemented | #4328, #4329 |
| RDR-073 tool reuse, pinned checkout, provenance, and issue-less polyglot matching | RDR-073's guarded sidecar provisioning exists, but no maintenance adapter consumes it or records maintenance provenance. | Not implemented | #4327, #4330 |
| Finding recurrence, dismissal reassessment, bounded repair, and revision revalidation | No finding identity, dismissal, repair-selection, or revalidation surface exists. | Not implemented | #4329, #4331 |
| Opt-in schedules, timezone/next occurrence, non-overlap, bounded catchup, budgets, disable/cancel, and UI/API/MCP parity | No maintenance schedule or dispatch surface exists. The mutation sweep is not equivalent evidence. | Not implemented | #4332 |
| Advisory PR integration preserving revisions/publication contracts and separating existing debt | No maintenance evidence reuse or advisory PR-audit path exists. | Not implemented | #4333 |
| External-project evaluation: actionable findings, false positives, gaps, latency, costs, repeated noise, and repair reviews | No admitted capability exists to evaluate; no measurement corpus or results are present. | Not implemented | #4328–#4333 |
| Guard-removal decision with schedules remaining opt-in | `maintenance_runs` is not registered, so it cannot be removed. RDR-073's separate guard is unchanged. | Retain default-off design requirement | #4328, future C75 rerun |
| Intent-traceability recipe: unlinked trees, missing phases, stale metadata, shared/cross-project ownership, false positives, partial remote coverage, report-only handoff | The required recipe is not shipped; #4340 remains open. | Not implemented | #4340 |

No test can be cited as passing an RDR-075 behavior, because neither its
approved EARS claims nor its implementation tests exist. Existing RDR-073 and
mutation-sweep tests must not be relabelled as maintenance-run proof.

## Validation evidence

- A repository-wide source inspection on 2026-10-15 found no
  `maintenance_runs`, `maintenance run`, or `general maintenance` implementation
  outside this audit and index entry. The checked `AgentRun::GOALS`,
  `FeatureFlags::DEFINITIONS`, schema, controllers, MCP tools, jobs, views, and
  specs therefore cannot provide behavior-test evidence for this Draft.
- `bundle exec rubocop` completed with **3,897 files inspected, no offenses**.
- `bin/coherence-check.mjs` completed: arrow references are valid; its reported
  reverse orphans, uncovered gap markers, staleness, and untagged-file signals
  predate and are unrelated to this unimplemented RDR-075 segment.
- `bundle exec rspec` completed 25,743 examples with one PostgreSQL deadlock in
  the unrelated `CreateMarketplaceEntries` migration spec and 27 Chromium
  unavailable pending system specs. A serial retry of
  `spec/migrations/create_marketplace_entries_spec.rb` passed: **2 examples,
  0 failures**. Neither result is presented as maintenance behavior evidence.

## Status, gaps, and rollout decision

**Status: Partially Implemented — planning only.** The focused gaps were
already separately filed rather than being re-filed as a catch-all: #4327
through #4333 cover the seven implementation phases, and #4340 covers the
required report-only intent-traceability recipe. Their open state matches the
direct source inspection above; no duplicate issue is warranted.

Keep `maintenance_runs` as a default-off per-tenant guard when Phase 1 creates
it. There is no shipped evidence that could support removal, and recurring
schedules must remain opt-in even after a future guard decision. RDR-073's
tool guard remains separately authoritative; this audit neither enables nor
weakens it.

Before a future final-acceptance rerun, merge the design, create and approve
the HLD/LLD/EARS arrow, complete RDR-073 final acceptance, deliver each
focused gap behind the guard, and record real external-project measurement.
That rerun must cite behavior tests and concrete code paths for every row
above; closure of child issues alone is insufficient.
