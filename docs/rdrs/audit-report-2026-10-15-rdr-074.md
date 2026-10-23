# RDR-074 Closeout Audit — 2026-10-15

**RDR:** [RDR-074: Settings-Aware Project Readiness](RDR-074-project-readiness.md)
**Closeout issue:** #4325
**Umbrella:** Tracks #4255 (this audit does not close it)
**Conclusion:** **Implemented**

## Scope and method

This audit compared shipped code and executable focused specs with the
RDR-074 validation criteria and the broader #4255 acceptance outcome. A
closed implementation issue was not used as evidence. The deterministic
structural evaluator is supplemented by the focused Godot/gdUnit4 lifecycle
and authorized non-UI bootstrap evidence recorded below.

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

## Godot/gdUnit4 product-acceptance evidence

Issue [#4463](https://github.com/viamin/paid/issues/4463) closes the consumer
lifecycle evidence gap. The historical Forager-iOS fixture remains the
missing-prerequisites state; the isolated Godot fixture supplies the merged
target-branch state without modifying that historical evidence.

Run the evidence locally or in an isolated CI worker with:

```bash
bin/validate-godot-gdunit4-readiness
```

The runner downloads Godot 4.4.1 and checks out gdUnit4 v5.1.1 at
`c924c7a01129b346453dd65f8d59e46613658832` into a temporary directory. It
runs Godot headlessly with
`res://addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode -a tests`
against the intentionally failing draft test and requires its nonzero outcome.
It also runs the focused lifecycle spec, which records these transitions:

1. strict GDScript prerequisites missing → `project_setup_pending` Inbox;
2. authorized operator explicitly queues one manual `bootstrap_readiness` run;
3. the bootstrap diff is accepted only inside the harness boundary;
4. a GitHub-confirmed bootstrap merge enqueues target-branch reevaluation and
   the satisfied snapshot clears the Inbox entry; and
5. the next `test_writing` draft accepts only `tests/` changes and has a real,
   intentionally red gdUnit4 command result.

This is acceptance evidence for `PROJECT-READINESS-009`; it supplements the
structural coverage for `PROJECT-READINESS-001` through `008`.

## Authorized non-UI bootstrap evidence

Issue [#4464](https://github.com/viamin/paid/issues/4464) closes the non-UI
product-acceptance gap. `trigger_readiness_bootstrap` is a confirmation-gated
tool action authorized with `ProjectPolicy#run_agent?` and delegates to the
same readiness-bootstrap admission service as the Inbox UI. Its permanent
coverage verifies authorization, current-readiness admission, active-run
deduplication, gap/prompt and token-accounting parity, and explicit retrigger
after a visible terminal failure.

## Rollout-guard disposition

No new rollout guard is required. The existing behavior is bounded by the
project TDD setting, persisted readiness evidence, an explicit authorized
trigger, a single-active-run database constraint, and the bootstrap write
guard. The product outcome must not be enabled through an automatic bootstrap
loop or a durable readiness latch.

## 2026-10-23 umbrella acceptance follow-up

**Tracks #4255; this evidence does not close the umbrella.** A final acceptance
review found that a project created directly with strict TDD or interactive
verification enabled did not schedule its first readiness evaluation: the
existing callback only covered later settings updates. `Project` now queues
that initial evaluation only when a readiness-relevant capability is enabled;
projects with neither capability enabled do not acquire unnecessary checkout
work. `PROJECT-READINESS-006` and its model coverage document this creation
path alongside the existing re-evaluation triggers.

The follow-up ran the project-readiness callback examples (6 examples, 0
failures), the bootstrap, write-guard, and lifecycle focused suite (25
examples, 0 failures, with the externally provisioned Godot command example
pending), and `bin/validate-godot-gdunit4-readiness` (2 examples, 0 failures).
The isolated validator downloaded Godot 4.4.1 and gdUnit4 v5.1.1, then
confirmed the intentionally failing gdUnit4 draft command. Its non-fatal
fontconfig warnings did not affect the result.
