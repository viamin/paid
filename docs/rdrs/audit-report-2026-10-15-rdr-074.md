# RDR-074 Closeout Audit — 2026-10-15

**RDR:** [RDR-074: Settings-Aware Project Readiness](RDR-074-project-readiness.md)  
**Closeout issue:** #4325  
**Umbrella:** Tracks #4255 (this audit does not close it)  
**Conclusion:** **Partially Implemented**

## Scope and method

This audit compared shipped code and executable focused specs with the
RDR-074 validation criteria and the broader #4255 acceptance outcome. A
closed implementation issue was not used as evidence. The current evaluator
scope is deterministic structural readiness; it must not be represented as
proof that a real consumer bootstrap lifecycle ran successfully.

## Executed focused-spec evidence

On 2026-10-15, the following command completed successfully against the test
database:

```sh
bundle exec rspec spec/services/projects/readiness_spec.rb \
  spec/services/projects/readiness/record_spec.rb \
  spec/models/project_spec.rb spec/models/agent_run_spec.rb \
  spec/services/inbox/queue_spec.rb spec/services/inbox/count_spec.rb \
  spec/services/inbox/availability_spec.rb spec/requests/agent_runs_spec.rb \
  spec/services/issues/upsert_from_github_spec.rb \
  spec/temporal/activities/mark_agent_run_failed_activity_spec.rb \
  spec/jobs/retry_failed_manual_run_job_spec.rb \
  spec/services/projects/readiness/bootstrap_write_guard_spec.rb \
  spec/temporal/activities/create_pull_request_activity_spec.rb
```

Result: **1,802 examples, 0 failures** in 2 minutes 39.7 seconds (random seed
10562). The command emitted existing GoodJob deprecation warnings, but no test
failures. This is focused structural-contract evidence, not evidence that a
real Godot/gdUnit4 lifecycle command ran.

## RDR-074 validation evidence

| Criterion | Shipped evidence | Test evidence | Result |
| --- | --- | --- | --- |
| Pure result has gaps and timestamp, without persistence or checkout acquisition | `app/services/projects/readiness.rb:14-39`; `app/services/projects/readiness/evaluate.rb:8-23` | `spec/services/projects/readiness_spec.rb` | Met |
| Strict/non-strict require CI, test directory, and command; TDD-off contributes no TDD gaps | `app/services/projects/readiness/rules/tdd.rb:11-91` | `spec/services/projects/readiness_spec.rb` covers strict Ruby, non-strict Python, and off | Met |
| Registered language fallback and specialized Godot/gdUnit4 detector | `app/services/projects/readiness/detectors.rb:7-16`; `detectors/godot.rb:10-43`; `detectors/language_commands.rb:8-52` | `spec/services/projects/readiness_spec.rb` covers the empty Forager-iOS fixture and configured language commands | Met |
| Persisted gap/timestamp output and cache invalidation | `app/services/projects/readiness/record.rb:7-34`; `app/jobs/evaluate_project_readiness_job.rb:5-19` | `spec/services/projects/readiness/record_spec.rb`; `spec/models/project_spec.rb`; `spec/models/agent_run_spec.rb` | Met |
| Authorized, auto-pick-independent Inbox lane with matching queue/count/availability behavior | `app/services/inbox/queue.rb:760-784`; `app/services/inbox/count.rb:141-144`; `app/services/inbox/availability.rb:226-229`; `app/models/project.rb:478-484` | `spec/services/inbox/queue_spec.rb`; `spec/services/inbox/count_spec.rb`; `spec/services/inbox/availability_spec.rb` | Met |
| Human-only, deduplicated bootstrap and merge-only re-evaluation | `app/controllers/projects/agent_runs_controller.rb:259-282`; `app/services/issues/upsert_from_github.rb:107-112`; `db/migrate/20261013103406_add_unique_active_bootstrap_readiness_index_to_agent_runs.rb:13-29` | `spec/requests/agent_runs_spec.rb`; `spec/services/issues/upsert_from_github_spec.rb`; retry/failure specs named in `PROJECT-READINESS-007` | Met for UI admission path |
| Harness-only bootstrap writes while preserving ordinary TDD phases | `app/services/projects/readiness/bootstrap_write_guard.rb:9-64`; `app/temporal/activities/create_pull_request_activity.rb:58-68,1161-1186` | `spec/services/projects/readiness/bootstrap_write_guard_spec.rb`; `spec/temporal/activities/create_pull_request_activity_spec.rb` | Met |

## #4255 product-acceptance gaps

The repository includes only the deliberately empty structural fixture at
`spec/fixtures/projects/forager-ios/`; it is not a merged-bootstrap lifecycle
fixture and does not execute a Godot command. No checked-in evidence proves
the sequence from merged bootstrap artifacts through target-branch
re-evaluation to a deliberately red next test-writing draft PR. The UI exposes
`POST /projects/:project_id/agent_runs/bootstrap_readiness`, but the audited
API Inbox controller only exposes list/detail/chat operations and no
equivalent bootstrap action; no corresponding tool surface was found.

Required focused follow-ups:

1. [#4463](https://github.com/viamin/paid/issues/4463) — Godot/gdUnit4
   bootstrap-to-red-draft lifecycle validation, preserving Forager historical
   evidence when available or using an isolated fixture.
2. [#4464](https://github.com/viamin/paid/issues/4464) — an authorized
   API/tool bootstrap action with parity to the existing UI action, including
   authorization, deduplication, failures, and accounting.

Both focused issues were created on 2026-10-15 and #4255 now has explicit
`Depends on #4463` and `Depends on #4464` entries. They remain open acceptance
work; this closeout continues to track #4255 without closing it.

## Rollout-guard disposition

No new rollout guard is required for this documentation-only closeout. The
existing behavior is already bounded by the project TDD setting, persisted
readiness evidence, an explicit authorized click, a single-active-run database
constraint, and the bootstrap write guard. The broader product outcome must
not be enabled through an automatic bootstrap loop or a durable readiness
latch.
