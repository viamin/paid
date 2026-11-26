# Closeout candidate query audit — 2026-11-26

Base: `48d1ab29ead0866ce6678155def7288f576084e1`. Environment: ARM64
devcontainer, Ruby 3.4.13, ActiveRecord 8.1.4.1, PostgreSQL 16.15, coverage
enabled. No production environment is deployed.

An earlier factory-heavy profile recorded 700 closeout-candidate queries,
700 plans, 17.72s planning and 0.14s execution. ActiveRecord's SQL visitor marks
unbound SQL literals and multi-value hash `IN` predicates unpreparable;
`exists?` also projects an unbound SQL literal. Enabling prepared connections
alone therefore did not prepare this lookup.

The candidate uses a scalar ID projection and bound evidence/status predicates.
The evidence alternatives remain parenthesized before the open-state check. All
project, hold, abandoned-retry, active-run and open-continuation filters remain;
the existing continuation `open` scope is retained. PostgreSQL's automatic
plan-selection policy is unchanged.

## Evidence

- The new restricted-role regression fails first because no named statement or
  generic-plan executions exist. It then passes across tenant A/B/A: eighteen
  real candidate lookups reuse one statement and a forced generic plan, while
  preserving each tenant's visibility. Forced planning is confined to this
  rollback-isolated regression, following the existing tenant test pattern.
- Existing evidence/correlation checks and new closed-no-code, open-continuation
  and queued-run checks pass. Final focused execution: **14 examples, zero
  failures/pending**, including the one-off timing example.
- The timing example loads the archived original query implementation alongside
  the candidate, using the same persisted positive, negative and closed cases.
  Each phase runs **700 uncached lookups**, with `plan_cache_mode=auto` and the
  same coverage instrumentation, logger, connection and fixture data.

| Phase | Wall | Caller CPU | Named statement | Plan uses |
| --- | ---: | ---: | --- | --- |
| Original 1 | 38.15s | 4.65s | none | not recorded for unnamed query |
| Candidate | 7.01s | 4.67s | one | 5 custom / 695 generic |
| Original 2 | 39.84s | 6.54s | none | not recorded for unnamed query |

The candidate is **82.0% faster** than the surrounding original timings' mean
for this lookup. This is not a whole-suite result. `pg_stat_statements` is not
installed in this private database, so this comparison does not claim a measured
server planning-time reduction. Prepared-plan counters are read from the actual
connection. Other Paid workloads remain active.

The first temporary-file invocation passed its assertions but incorrectly hit
the full-suite coverage floor because absolute temporary paths are not
classified as focused. The corrected focused invocation and final fourteen-case
run both pass with coverage enabled; the whole-suite 80% gate is unchanged.

Full CI `45845384634` on `8358c9cc26d69ebb6fe67cced216cf789392bceb`
passes 31,308 examples, zero failures, five existing pending cases and 95%
combined coverage. All six artifact digests match; system acceptance also passes.
Security CI flags SQL interpolation in the new predicate. The follow-up keeps
the bound open-state predicate in the existing SQL builder and passes it to
`where` directly, without a scanner suppression. The follow-up passes all 13 focused behavior/tenant examples, zero failures
or pending cases, with coverage enabled and seed 24680. Brakeman completes with zero warnings and zero errors on the same application
source; changed-file lint and coherence pass (existing repository warnings
remain). Full CI on the follow-up revision remains pending. Raw source hashes, archived
implementation, regressions, controls and logs are retained under
`/tmp/paid-testprof-audit/closeout-plans/` in the devcontainer.

## Representative control

Seven factory-heavy files retain the same 599 examples, execution order and
1,632 factory calls in original/candidate/original runs. Coverage, FactoryProf,
RSpecDissect, TestProf GC profiling, INFO logging, seed 24680, restricted
application roles and the unavailable localhost Temporal endpoint remain fixed.
Every leg uses a fresh database restored only after a positive empty-table check.

| Phase | Process wall | User CPU | Example execution | Major page faults |
| --- | ---: | ---: | ---: | ---: |
| Original 1 | 417.05s | 225.45s | 381.61s | 17,796 |
| Candidate | 466.34s | 255.05s | 418.93s | 26,458 |
| Original 2 | 629.86s | 286.03s | 551.47s | 41,289 |

All three runs pass with zero failures or pending cases. Each covers 47,981
application lines; raw line positions differ only at two moved lines in this
SQL builder. GC takes 18.82 / 22.34 / 22.75 seconds, so it is not the dominant
cost in this sample. Live Paid jobs/workers remain active, and the host swaps.
No other audit test or linter runs during these legs. The candidate falls between
the controls: **repeatable workload improvement is unproven**, despite the
isolated query's measured gain. Do not extrapolate that microbenchmark to a
whole-suite percentage. Evidence: `/tmp/paid-testprof-audit/closeout-macro/`.
