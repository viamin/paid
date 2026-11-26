# RSpec performance audit: 2026-11-26

## Scope and environment

Audit base: `045bed8556c787f921ec539a51a5e617733051b7`.
Worktree: `.worktrees/test-prof-audit`, branch `perf/test-prof-audit`.
The shared-configuration follow-ups use branch
`perf/test-prof-shared-configuration`, on base
`6fcdc856f753c12dee5cc9933a32a1f8c9118e7b` for the activity comparison below.
Acceptance environment: Paid devcontainer, Ruby 3.4.13, ARM64. Focused tests use
the newly created, isolated `paid_test_prof_audit` database. No production
environment or deployment is involved.

The other session's full-suite benchmark remains untouched. Its artifacts are
in `tmp/benchmarks/full-ci-20261126/`, at benchmark revision
`a8c8317e9180a81cb21c71bc4654ed2eafca0139`. This is a different revision from the
audit base; its timings identify candidates rather than establish acceptance
of this change.

## Full-suite observations

The five hosted non-system shard reports contain 31,284 examples, no duplicate
example IDs, and 4,771.9 seconds of summed example time. That is approximately
80 minutes of serial work, not 80 minutes of hosted parallel elapsed time.
The slowest hosted shard reports 1,023 seconds of execution, excluding setup.

| Area | Examples | Summed hosted example seconds |
| --- | ---: | ---: |
| Services | 14,822 | 2,369.8 |
| Temporal | 3,462 | 761.7 |
| Requests | 3,107 | 568.7 |
| Models | 4,951 | 392.7 |
| Jobs | 1,288 | 285.7 |

High-cost files include `run_agent_activity_spec.rb` (153.1 seconds),
`agent_run_spec.rb` (130.9), `root_prerequisite_ranking_spec.rb` (107.1),
`scan_paid_prs_activity_spec.rb` (101.4), and request `agent_runs_spec.rb` (79.1).
File duration alone does not identify whether setup, SQL, subprocesses, or
assertions cause that cost.

The local benchmark runs five complete shards and the system suite concurrently
alongside existing development workloads. Its recorded environment has ten CPUs;
the observed one-minute load median was 22.8 over the first 177 samples. A later
sample reported approximately 8.2 GB of occupied swap. Completed local shards 1
and 4 had median per-example slowdowns of approximately 4.0 compared with their
hosted counterparts, considering examples whose hosted duration exceeded 10 ms.
Architecture, coverage, resource contention, and database state are confounders.
The isolated audit database's schema load also encountered a PostgreSQL WAL-write
wait. A single sampled wait does not establish its share of suite runtime.

The completed local non-system shards subsequently reported execution durations
of 4,560–5,596 seconds, with per-example median slowdowns of 4.0–5.49 relative
to the hosted reports. The benchmark reported eight non-system example failures
across three shards; those are not evidence of a passing full suite. Its owning
session retains responsibility for that benchmark and its failure diagnosis.

### Published checkpoint: full CI

CI run `45774582989` on `6fcdc856f753c12dee5cc9933a32a1f8c9118e7b`
produced all five shard artifacts: 31,303 examples, zero failures, and five
pending cases. The pending cases are the same four optional execution-runner
resource contracts and optional real gdUnit4 acceptance case as the earlier
benchmark. The combined coverage artifact reports 95% line coverage.

Summed example execution is 5,065.0 seconds versus the earlier benchmark's
4,771.9 seconds. The slowest shard's execution is 1,226.8 versus 1,023.0
seconds. Different revisions and hosted-runner variability prevent attributing
the difference to this patch, but these results do not show whole-suite halving.
The ranking file decreased from 107.1 to 55.0 example seconds; dashboard
decreased from 57.9 to 57.2 and candidate selection from 60.5 to 56.8.
The published checkpoint excludes the activity/anomaly follow-ups below.

Downloaded ZIPs were verified against GitHub's artifact digests. Raw reports,
combined coverage metadata, and the comparison are under
`/tmp/paid-testprof-audit/ci-5463-6fcdc856/`. The complete suite still requires
broader improvements; selected local gains cannot establish its runtime target.

## Follow-up: shared configuration and focused dashboard sections

Measured against commit `90f5c341a159bfdfb745bf74530b14a6ca4a989f`, the candidate-source
and dashboard specs reuse stable configuration through existing TestProf group
transactions. Dashboard component examples request their asserted sections using
its public `only:` interface; full-response and cross-account integration cases
retain complete assembly. All 243 examples and all 224 dashboard expectation
lines remain in this follow-up.

The same absolute profile paths, private database, seed 24680, `COVERAGE=false`,
`FPROF=1`, and `RD_PROF=1` were used for each comparison:

| Workload | Seconds | Examples | Failures | Factory records |
| --- | ---: | ---: | ---: | ---: |
| Before follow-up | 360.73 | 243 | 0 | 2,320 |
| Shared configuration | 314.01 | 243 | 0 | 1,169 |
| Shared configuration and section selection | 272.72 | 243 | 0 | 1,169 |

This is a 24.4% observed reduction for two files, not a whole-suite result.
Scenario agent runs and issues remain per example. The shared-configuration
comparison retains 361 runs and 548 issues while reducing projects from 265 to
37, users from 534 to 78, and accounts from 248 to nine. Normal factory callbacks,
validations, ownership relationships, and tenant enforcement remain enabled.
Raw reports are `shared-config-before.json`, `shared-config-after.json`, and
`section-scoped-after.json` under `/tmp/paid-testprof-audit/`.

The complete shared-fixture isolation file passes all 16 examples with seed
97531. Disabling `refind` for the two added contexts makes two of the four new
examples fail; this diagnostic checks that mutated Ruby objects cannot leak
between examples. The diagnostic changes only temporary test registration.

With coverage enabled and seed 97531, both dashboard versions pass all 101
examples. Both cover the same 289 lines in `app/services/dashboard/stats.rb`,
with no lost or gained lines. This focused comparison does not replace the
normal whole-suite 80% coverage gate. Reports: `dashboard-coverage-before.json`,
`dashboard-coverage-after.json`, and `dashboard-coverage-comparison.json`.

A read-only logging microprobe ran the same eligibility query 100 times in each
of four alternating debug/warn batches. Times were 5.05, 2.74, 2.80, and 1.84
seconds. Warm-up and changing system load confound that downward trend; this
does not establish a suite-level logging benefit. No logging policy changed.

The follow-up passes `bin/lint --changed`, `git diff --check`, and the LID
coherence command. Coherence still emits existing repository-wide warnings.
The simplicity review retains explicit shared contexts and the existing public
dashboard interface without a new fixture framework or global defaults.

## Follow-up: activity setup and repeated executions

Failure-marking, PR-creation, and issue-analysis specs share their uncustomized
project configuration through the existing context, now named `with stable
project`. Custom nested project/owner overrides remain per example. Provisioning
uses the renamed context without changing its fixture contract.

Three groups consolidate checks for identical inputs and operations: error
state/logging, successful issue analysis, and successful PR completion/sync.
Their assertions remain, including token accounting, diagnostics, notification
jobs, PR labels, and local row creation. Distinct cancellation, transport,
trust, malformed-response, and configuration cases remain independent. The
PR status, URL, and number checks use one attribute matcher; its job and row
count checks use a composed block matcher. The separate creation-log example
keeps the main completion check within the style guide's size limit.

The same three absolute profile paths, seed 24680, private database,
`COVERAGE=false`, `FPROF=1`, and `RD_PROF=1` produced:

| Workload | Before | After |
| --- | ---: | ---: |
| Execution seconds | 430.15 | 339.35 |
| Examples | 303 | 294 |
| Failures / pending | 0 / 0 | 0 / 0 |
| Factory records | 2,423 | 992 |
| Projects | 302 | 21 |
| Users | 606 | 44 |
| Agent runs | 342 | 333 |
| Issues | 266 | 257 |
| Top-level factory seconds | 182.03 | 107.46 |

That is a 21.1% observed reduction for these files. The devcontainer still
runs Paid workers and agent containers, so varying contention limits timing
comparisons. No callbacks, rendering, validations, tenant constraints, or
application database settings were disabled. Reports:
`activity-shared-project-before.json` and `activity-shared-project-after.json`.

The strengthened isolation file passes all 16 examples with seed 97531,
including owner settings, credential status, and scenario-row rollback.
Provisioning discovery finds all 384 examples after the context rename; this
is a dry run, not evidence that those 384 examples executed. Temporary diagnostic
wrappers corrupt the saved failure message, issue analysis state, and PR number.
The three consolidated examples fail on exactly those fields, preserving the
removed examples' regression checks. Reports: `activity-isolation.json`,
`activity-provisioning-discovery.json`, and `activity-regression-mutant.json`.

Coverage-enabled focused comparisons pass the original 12 and consolidated
three examples with seed 97531. They retain identical covered-line sets in all
three activities: 207 lines for analysis, 225 for PR creation, and 68 for failure
marking. Reports: `activity-coverage-before.json`, `activity-coverage-after.json`,
and `activity-coverage-comparison.json`. The normal whole-suite coverage gate
remains unchanged.

## Follow-up: anomaly checks and provider value tests

Five token-outlier examples repeat one detection against the same seven-run
scenario. One aggregate example now checks the detected metric/type, persisted
row, warning log, and notification fields/severity. Other anomaly scenarios keep
their original inputs and assertions. Historical runs still use per-example
factories; only project configuration is shared.

Five effective-provider normalization cases instantiate `AgentRun` directly.
They only read attributes and normalize names. The existing persisted legacy
alias integration also checks the effective provider after reloading the run.

Using the same two absolute profile paths, seed 24680, private database, and
FactoryProf/RSpecDissect options, all 29 original and 25 retained examples pass.
Runtime decreases from 59.88 to 54.31 seconds, while factory records decrease
from 442 to 246, runs/issues from 142 each to 109 each, and projects from 28 to
two. The observed runtime gain is 9.3%; factory counts alone would overstate it.
Reports: `anomaly-values-before.json` and `anomaly-values-after.json`.

Coverage-enabled runs with seed 97531 also pass all 29 and 25 examples. They
cover identical sets of 95 anomaly-service lines and both executable lines of
the effective-runner method. The model comparison is scoped to that method,
not a claim about all AgentRun callbacks. Raw comparison:
`anomaly-values-coverage-comparison.json`.

The consolidated anomaly example independently catches three injected defects:
an unsaved result, wrong anomaly direction, and missing notification. Replacing
provider normalization with the raw requested agent type makes four of five
value cases fail on the expected values. Reports:
`anomaly-retained-check-mutant.json` and `provider-value-check-mutant.json`.
These are temporary negative controls, not skipped or failing committed tests.

LID mode: Full; version: 1.3.0. Existing TEST-SUITE-011 and TEST-SUITE-017
govern the fixture changes. The final working-patch simplicity pass against
HEAD `6fcdc856f753c12dee5cc9933a32a1f8c9118e7b` retains existing contexts,
explicit assertions, and ordinary model construction without a new test
framework. Lint and coherence pass; coherence retains repository-wide warnings.

## First changes and measured effect

The prerequisite-ranking boundary examples created 500 irrelevant issues or
500 prerequisites even though their assertions concern the configured node
limit. They now exercise a limit of five with normal factories, callbacks,
validations, and queries. The separate 500-node maximum-depth query-bound test
is retained. The ranked-root test creates `MAX_RANKED_ROOTS + 1` roots instead
of twelve; it still crosses the real five-root admission boundary.

Dashboard examples repeatedly constructed the same five-run scenario and
calculated the same response to inspect individual fields. Related assertions
now share one calculation and use example-scoped aggregate failures. All 224
dashboard expectation lines are retained, with an identical multiset before
and after. Distinct time, cache, and scenario tests remain separate.

| Focused workload | Before | After |
| --- | ---: | ---: |
| Execution seconds | 241.44 | 50.74 |
| Examples | 30 | 21 |
| Failures / pending | 0 / 0 | 0 / 0 |
| Factory invocations | 2,021 | 299 |
| Top-level factory invocations | 1,832 | 176 |
| FactoryProf top-level seconds | 230.73 | 43.82 |
| Dashboard setup seconds | 62.30 | 32.96 |

This sample ran approximately 79% faster with 85% fewer factory invocations.
Concurrent system load varied, so this is an observed result, not a prediction
of whole-suite speedup. The record-count reduction is independent of that load.
RSpecDissect attributes factory construction inside example bodies to example
time rather than before-hook setup; use FactoryProf as well when interpreting
the ranking examples.

Both runs used `COVERAGE=false FPROF=1 RD_PROF=1`, seed `12345`, and
`PAID_TEST_DATABASE=paid_test_prof_audit`. The baseline used unchanged copies
of the two spec files. The selection was:

```text
--example-matches 'seeds bounded|reports unavailable|evaluates admission|with no agent runs|with agent runs '
```

Raw audit evidence is retained in `/tmp/paid-testprof-audit/`: `before.json`,
`before.log`, `after.json`, `after.log`, and `hotspot-analysis.json`.
No global TestProf defaults, application callbacks, or test coverage gates were
disabled by this change.

The complete two changed files passed with seed `54321`: 125 examples, no
failures or pending examples, in 421.86 seconds. The retained maximum-depth
example accounted for 215.92 seconds. This broader run is not comparable with
the 30/21-example focused workload above.

A subsequent change constructs that same 500-node chain leaf-first, avoiding
growing ancestor walks during cycle validation without skipping any validation.
All 24 ranking examples passed again with seed `54321` in 195.74 seconds.
The maximum-depth example decreased from 215.92 to 141.85 seconds (34%); summed
ranking-example time decreased from 258.20 to 195.70 seconds. The other 23
examples were collectively slower on the second run, illustrating the ambient
timing variability. Both builds retain 500 issues, 499 dependency records,
the final graph shape, and the bounded-query assertion. Evidence:
`leaf-first-ranking.json` and `leaf-first-ranking.log`.

The three reduced graph-boundary examples were also exercised against temporary
RSpec mutations: account-wide ancestor selection, ignoring truncation before
ranking, and admitting every candidate root before limiting results. All three
failed at the intended assertions (or the missing expected ranking). Mutations
were injected only in that diagnostic process; application source was unchanged.
Evidence: `full-changed-files.json` and `boundary-mutants.json`.

## Deeper investigation

An additional FactoryProf/RSpecDissect sample exercised eight examples
from agent execution, AgentRun, and auto-pick candidate selection. All eight
passed in 39.04 seconds, creating 179 factory records including 31 agent runs,
22 projects, 43 users, and 22 GitHub tokens. Top-level factory work consumed
27.06 seconds; agent-run construction accounted for 21.09 seconds of that.
The three AgentRun examples took 19.96 seconds despite negligible before-hook
time: their fixture creation is inside the examples. The three agent-execution
examples already reuse stable project setup and spent only 1.26 seconds in
setup out of 7.36 seconds. Shared group setup alone will not resolve every
hotspot. Raw evidence: `deep-sample.json` and `deep-sample.log`.

1. Inspect AgentRun factory cascades in status/history examples. Reuse a project
   within a scenario only where distinct projects are not part of the assertion;
   preserve explicit cross-project and cross-tenant coverage. Keep scenario
   issues/runs separate. Profile SQL inside the remaining activity body work.
   A default project creates its own creator and a token whose factory creates
   another user. The observed 22 projects and 43 users reflect that cascade.
   Reuse an explicit actor only in scenarios that do not require distinct
   credential ownership; do not change global factory ownership defaults.
   The retained maximum-depth graph also constructs 499 dependencies through
   `IssueDependency` validation. Each save calls `Issues::DependencyCycle`, which
   reloads account adjacency and external edges before checking the proposed
   edge. Repeated whole-graph reads make fixture construction grow quadratically
   in graph size even when the ranking query itself is bounded. Preserve real
   cycle validation while investigating this cost; bypassing it would change
   the acceptance environment.
2. Examine request authentication/project setup and database query time.
   Reuse existing stable contexts only where tenant, role, and association
   identity semantics remain intact.
3. Measure one local worker after the benchmark finishes, then increase
   concurrency while recording memory, swap activity, database waits, and
   throughput. Choose concurrency from throughput rather than CPU count alone.
4. Review semantic overlap by trigger, assertions, and failure scenarios.
   Four `_dbless_spec.rb` files have database-backed siblings, but a shared
   subject does not make database integration coverage redundant. Do not delete
   either category without showing which remaining test catches its defect.
5. Evaluate database planning costs using representative data. Test connections
   currently allow PostgreSQL JIT; one captured eligibility query did not invoke
   JIT in read-only EXPLAIN comparisons. That sample does not justify changing
   the suite's database policy.

The first changes reduce avoidable work; they do not establish that the complete
suite now meets a runtime target. Full-suite timing and aggregate coverage still
need the normal CI execution after integration.
