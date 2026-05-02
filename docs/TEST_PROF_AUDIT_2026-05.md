# TestProf Audit - May 2026

## Summary

This audit used `test-prof 1.6.1` beyond the repo's existing `FPROF` / `FDOC` workflow and focused on:

1. factory churn
2. SQL/event volume
3. RSpec setup and `let` overhead
4. slow example-group shape
5. CPU-heavy outliers

Two request-spec hotspots were optimized as part of the audit:

- [`spec/requests/github_tokens_spec.rb`](../spec/requests/github_tokens_spec.rb)
- [`spec/requests/agent_runs_spec.rb`](../spec/requests/agent_runs_spec.rb)

Both were spending time on factory-created `created_by` users and projects that the assertions never used. The fixes stayed low risk and spec-local: reuse the already-created request user/account/project graph instead of letting `github_token` and `project` factories create extra users implicitly.

## Commands

The audit command wrapper added in this pass is [`bin/test-prof-audit`](../bin/test-prof-audit).

Most useful entrypoints:

```bash
bin/test-prof-audit hotspot-map
bin/test-prof-audit requests-deep
bin/test-prof-audit type-breakdown
bin/test-prof-audit file spec/requests/github_tokens_spec.rb
```

All profiling runs use `COVERAGE=false` and write logs/artifacts under `tmp/test_prof`.

## Ranked File Hotspots

Only successful profiling runs are ranked here. Targets with failing or incomplete runs are listed later under blockers so they do not distort prioritization.

| Hotspot | Runtime | Dominant profiler signal | Likely root cause | Low-risk fix | Expected impact |
| --- | ---: | --- | --- | --- | --- |
| `spec/temporal/activities/run_agent_activity_spec.rb` | `67.08s` | plain profile shows a few very heavy timeout/fallback examples | expensive fallback/log-scan scenarios and container-oriented setup | isolate log fixtures, shrink fallback scenario setup, and use targeted `TEST_STACK_PROF` on top 3 examples | `large` |
| `spec/services/containers/git_operations_spec.rb` | `59.44s` | plain profile; top examples are shell/fs heavy | expensive git sandbox setup and repeated hook-install scenarios | share more fixture repos/helpers and stub shell boundaries earlier in examples | `large` |
| `spec/temporal/activities/scan_paid_prs_activity_spec.rb` | `56.28s` | plain profile shows repeated review-goal state-machine scenarios | many complex PR/review-run graphs per example | collapse helper graphs so each example creates only the required issues/runs | `large` |
| `spec/requests/agent_runs_spec.rb` | `52.75s` before, `41.44s` after | `FPROF`, `EVENT_PROF`, `RD_PROF` | repeated request-spec setup, heavy `project` / `user` / `agent_run` graphs, lots of SQL | reuse current-account creator fixtures; keep narrowing top-level lazy setup, especially `project` and `issue` | `large` |
| `spec/services/containers/provision_spec.rb` | `51.22s` | plain profile shows watchdog/timeout concentration | timeout simulation and container-watchdog scaffolding dominate | extract lighter timeout helpers and reduce duplicated heartbeat/clock setup | `medium` |
| `spec/requests/projects_spec.rb` | `22.12s` | plain profile shows request-spec setup and sort/metrics scenarios | similar request-spec factory graph pressure to `agent_runs_spec` | apply the same creator-reuse pattern for `project` / `github_token` / metric fixtures | `medium` |
| `spec/requests/github_tokens_spec.rb` | `6.06s` before, `4.18s` after | `FPROF`, `EVENT_PROF`, `RD_PROF` | extra `user` creation through `github_token.created_by` and `project.created_by` | reuse current-account creator fixtures and keep project setup narrow | `medium` |
| `spec/services/github_client_spec.rb` | `2.68s` | plain profile only | not a current hotspot; mostly fast mocked API behavior | no immediate work; leave out of next optimization wave | `small` |

## Top 20 Slow Examples Observed

These are the slowest examples surfaced during the audit runs across the inspected hotspot files.

| Example | Runtime |
| --- | ---: |
| `Containers::GitOperations#commit_uncommitted_changes rejects commits with binary files` | `4.24s` |
| `Activities::RunAgentActivity loop guardrail handling returns a paused result when the run was already paused during loop handling` | `2.79s` |
| `AgentRuns POST /projects/:project_id/agent_runs/quick_create when not authenticated redirects to the sign in page` | `2.40s` |
| `AgentRun scopes .finished includes completed, failed, cancelled, timeout, retried, auth_expired, and rate_limited runs` | `2.29s` |
| `Activities::RunAgentActivity#execute with fallback enabled reclassifies timeout output as rate limited when quota message is within the log scan window` | `2.06s` |
| `AgentRuns POST /projects/:project_id/agent_runs/:id/retry when not authenticated redirects to the sign in page` | `2.01s` |
| `AgentRuns GET /agent_runs when authenticated sorts agent runs ascending via Ransack sort params` | `1.92s` |
| `Containers::GitOperations#clone_and_setup_branch raises CloneError when partial clone cleanup fails` | `1.88s` |
| `AgentRuns GET /projects/:project_id/agent_runs/new when authenticated exposes goal-specific provider defaults to the goal toggle controller` | `1.83s` |
| `AgentRun scopes .search_by_goal matches by goal column value` | `1.78s` |
| `AgentRun.claim_next_queued_run claims a specific queued run and transitions to pending` | `1.68s` |
| `Activities::ScanPaidPrsActivity when paid_agent is enabled and the last create_pr run is newer than the last review emits a paid_agent_review_pending trigger` | `1.61s` |
| `Activities::RunAgentActivity#execute with fallback enabled does not reclassify timeout when quota message falls outside the bounded log scan window` | `1.56s` |
| `Containers::GitOperations#clone_and_setup_branch when clone fails with a transient DNS/network error retries on 'Temporary failure in name resolution'` | `1.53s` |
| `AgentRuns POST /projects/:project_id/agent_runs/:id/terminate when authenticated cancels a paused run without marking it failed` | `1.41s` |
| `GithubTokens POST /github_tokens/:id/retry_validation when authenticated resets stuck validating tokens and enqueues job` | `1.30s` |
| `GithubTokens GET /github_tokens/:id/validation_status when authenticated shows stuck state for stale pending tokens` | `1.22s` |
| `AgentRun scopes .search_by_goal returns all runs when query is blank` | `1.21s` |
| `AgentRun scopes .active includes pending and running runs but not queued` | `1.14s` |
| `AgentRun.next_queued_run with all 6 priority tiers produces correct ordering across all tiers` | `1.12s` |

## Request-Suite Shape Findings

`TPS_PROF=10` and `TAG_PROF=type` were especially useful for broad prioritization, but they answer different questions:

- `TPS_PROF=10` on `spec/requests` tells us which request suites have poor examples-per-second.
- `TAG_PROF=type` only becomes useful when run across the broader `spec` tree, not just `spec/requests`, because every request spec already has the same `type`.

- Lowest-TPS request suites in the full `spec/requests` pass were:
  - `AgentRuns` at `4.81 TPS`
  - `GithubTokens` at `4.2 TPS`
  - `Api::SecretsProxy` at `4.49 TPS`
  - `Knowledge::Search` at `4.2 TPS`
  - `Api::GithubProxy` at `4.76 TPS`
- Additional high-cost request subareas surfaced by the accompanying `--profile` output during the request-suite run were:
  - `Projects::PreCommitRequirements` at `11.29s / 10 examples`
  - `Projects::PrTemplates` at `2.93s / 5 examples`
  - `Api::Proxy::KnowledgeSearch` at `4.25s / 8 examples`
  - `Projects::ServiceContainers` at `3.48s / 10 examples`
  - `Projects::CostDashboards` at `1.77s / 6 examples`

This shifted the next request-spec queue slightly: after `Projects`, the next high-value audit targets are no longer just the biggest files by line count, but the lowest-TPS groups and the highest average-cost subareas.

## Implemented Improvements

### `spec/requests/github_tokens_spec.rb`

- Reused the already-created request `user` as `created_by` for same-account `github_token` fixtures.
- Reused the same `user` as `created_by` for supporting `project` fixtures.
- Used `:without_creator` for foreign-account tokens that are only needed for authorization coverage.

Measured improvement:

| Metric | Before | After | Change |
| --- | ---: | ---: | ---: |
| Plain runtime | `6.06s` | `4.18s` | `-31.0%` |
| `FPROF` total factories | `191` | `151` | `-20.9%` |
| `FPROF` `user` factory calls | `94` | `54` | `-42.6%` |
| `FPROF` factory time | `3.142s` | `2.160s` | `-31.3%` |
| `RD_PROF` setup time | `2.415s` | `2.197s` | `-9.0%` |

### `spec/requests/agent_runs_spec.rb`

- Reused the already-created request `user` as `created_by` for the top-level `github_token`.
- Reused the same `user` as `created_by` for the top-level `project`.
- Reused the same `user` for same-account secondary projects in sort scenarios.
- Used `:without_creator` for both `github_token` and `project` in foreign-account authorization scenarios.

Measured improvement:

| Metric | Before | After | Change |
| --- | ---: | ---: | ---: |
| Plain runtime | `52.75s` | `41.44s` | `-21.4%` |
| `FPROF` total factories | `1383` | `1042` | `-24.7%` |
| `FPROF` `user` factory calls | `531` | `190` | `-64.2%` |
| `FPROF` factory time | `37.965s` | `28.091s` | `-26.0%` |
| `RD_PROF` setup time | `14.123s` | `12.036s` | `-14.8%` |

## FactoryDoctor Findings

Targeted `FDOC=1` runs on the two optimized request hotspots both reported `Looks good to me!`.

- `spec/requests/github_tokens_spec.rb`
- `spec/requests/agent_runs_spec.rb`

That is useful signal: the next improvements here should stay focused on factory graph size, setup placement, and high-SQL examples, not on replacing `create` calls that are already persistence-justified.

## Next Fixes To Implement

These are the next low-risk candidates, in order:

1. `spec/requests/projects_spec.rb`
   Reuse the request user as `created_by` for same-account `project` and `github_token` fixtures; trim metric/setup graphs in sort and dashboard-style examples.
2. `spec/requests/agent_runs_spec.rb`
   Narrow the expensive `project` and `issue` lazy setup further in the slowest `new`, `retry`, and `authorization` examples.
3. `spec/models/agent_run_spec.rb`
   Fix the Docker boot/test constant issue, then run `FPROF` and trim queue-ordering scenario factories.
4. `spec/services/containers/git_operations_spec.rb`
   Focus on the binary-file and clone-failure examples with helper consolidation and fewer real-ish sandbox setups.
5. `spec/temporal/activities/run_agent_activity_spec.rb`
   Use `TEST_STACK_PROF` on the timeout/fallback outliers after first trimming repeated log and provider setup.

## Notes and Blockers

- `let_it_be` remains out of scope. The repo's tenant-context wrapper still makes `before(:context)` setup risky.
- `spec/models/agent_run_spec.rb` had 15 failures because `Docker` was not loaded in this environment. The passing-example timings are still useful as a hotspot signal, but a clean rerun is required before making file-level optimization decisions there.
- `spec/temporal/workflows/git_hub_poll_workflow_spec.rb` had 1 failure due to `Temporalio::Workflow::Definition::VersioningBehavior` not being available during the run. Fix that first, then re-profile.
- `FDOC` is now wired into the audit runner, but this report intentionally prioritizes the stronger signals already captured from `FPROF`, `EVENT_PROF`, `RD_PROF`, `TPS_PROF`, and the measured request-spec improvements. Run `bin/test-prof-audit file <path>` or `bin/test-prof-audit requests-deep` to collect the current FactoryDoctor output before the next optimization wave.
