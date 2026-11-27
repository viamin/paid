# Execution scenario performance audit — 2026-11-27

LID Full, version 1.3.0; TEST-SUITE-011/017/032/033/034.

## Scope and environment

Reduce repeated work in `RunAgentActivity#execute` specs while retaining distinct
execution and failure contracts. Base: `8396d1a2b01e612694d0e2ecae1db2f73b24246e`
(PR #5604). Application code, gems, global fixtures and tenant enforcement are
unchanged. All acceptance runs use the ARM64 devcontainer and a dedicated
PostgreSQL database, a non-superuser role without BYPASSRLS, and prepared
statements. Paid has no deployed production environment.

## Changes

- Consolidate identical successful execution, timeout, fallback accounting,
  cleanup cancellation, failure and issue-goal operations. Retain their assertions
  and separate scenarios with different runner state or fallback settings.
- Batch six negative Codex agent-authored payloads into one JSONL response.
  Preserve each input payload and the independent positive provider diagnostics.
  Positive diagnostic alternatives remain separate examples.
- Initialize stable authentication/fallback configuration in nested TestProf
  fixture transactions, using a fresh user object. Runs, issues and mutable
  execution state remain per example, with ordinary callbacks and validation.
- Test circuit classification with threshold one; retain dedicated three-failure,
  cooldown and recovery scenarios.
- Bulk-insert the log-window dataset through the existing helper. Put all rows
  inside the current attempt so the outside-window case tests the row-count
  limit. Ordinary logging and split-chunk scenarios remain.

The target changes from 205 to 180 examples. FactoryProf records 235 → 202 run
factories, 229 → 197 issue factories, and SQL EventProf records 55,199 → 44,912
SQL events. These counts support the diagnosis; timing determines the gain.

## Timing

Sequential processes on the same host boot, with identical options within each
pair. RSpec durations exclude process boot; wall times include it.

| Pair | Original / candidate examples | RSpec seconds | Wall seconds | RSpec reduction |
| --- | --- | --- | --- | --- |
| FactoryProf + RSpecDissect + SQL EventProf, seed 24680 | 205 / 180 | 78.91 → 69.95 | 88.44 → 78.85 | 11.36% |
| Warm repeat, same profilers and seed | 205 / 180 | 100.21 → 69.79 | 111.79 → 78.01 | 30.35% |
| Coverage enabled, seed 97531 | 205 / 180 | 99.45 → 97.84 | 110.35 → 108.49 | 1.62% |

All six runs pass with no pending examples. The two profiled pairs average a
21.98% duration reduction. Original durations vary substantially; these trials
do not establish a consistent 25% reduction, a whole-CI speedup, or global Pareto
optimality. A host restart interrupted an earlier trial; its empty reports were
rejected and the original control rerun on the current boot.

Measured source snapshots and launch SHA-256 digests distinguish profiler runs
from subsequent formatting-only cleanup. The cleanup removes blank lines and two
unused mock-block return values, retaining every assertion. Final-source normal
and mutation acceptance is recorded separately below.

## Regression evidence

Coverage comparison under seed 97531 covers the identical 48,785 application/library
lines, with none lost or gained. The targeted slice reports 38.01% coverage;
the normal whole-suite 80% gate is unchanged. Line overlap alone was not used to
justify removal.

Bounded deliberate-fault comparisons use identical application sources and fault
manifests, fork isolation, nonempty test selection, and passing neutral controls.
They are not exhaustive generated mutation scores.

| Comparison | Original / retained examples | Evil faults detected | Neutral controls | Isolation errors |
| --- | --- | --- | --- | --- |
| First consolidation and circuit changes | 35 / 16 | 16 → 17 of 23 | 9 pass in both | 0 |
| Additional cancellation, failure and issue-goal consolidation | 14 / 8 | 7 → 7 of 11 | 4 pass in both | 0 |
| Final-source output attribution and log-window boundary | 3 / 3 | 2 → 3 of 3 | 2 pass in both | 0 |

No detection was lost in either comparison. The additional detected fault omits
runner preflight: the consolidated example now requires that call rather than
only stubbing it. Surviving faults remain explicit limitations; some mutate paths
outside the selected workload. The first comparison predates the six additional
consolidations, which have their own comparison.

The final-source boundary comparison additionally detects removal of the log
limit. The previous outside-window dataset fell outside the attempt-time filter,
so it could not detect that fault. Both versions detect missing output attribution
and an incorrectly tiny log window.
Final spec source SHA-256:
`c3a675aff94f2f27525aca649b4344bbe5cfcff011d4b7bd9af457cf51bf43f6`.
Final source passes all 380 examples in the activity file and both companions
with seed 86420: zero failures, pending examples or outside-example errors.
Duration: 98.11 seconds; process wall time: 109.65 seconds. Its broader activity
coverage is 49,277 lines (38.40%); this is separate from the matched target-only
coverage comparison above.

Five isolation probes pass with seed 24680: mutate settings, runner eligibility,
runner state, project attributes/association cache and run state, then verify the
next example sees restored fixtures, fresh run IDs and the outer defaults. An
initial probe expected bare runner names; correcting it to expect Paid's persisted
routing keys made the probe match the actual settings contract.
The same five probes pass on final source with seed 97531. Final lint/coherence
results are recorded with the publication evidence.

## Tooling and follow-up

- [Mutant #96](https://github.com/viamin/mutant/issues/96): bounded per-test
  outcome/cost observations for further redundancy analysis.
- [Mutant #98](https://github.com/viamin/mutant/issues/98): multiple precise
  covered-subject annotations on consolidated examples.
- [Mutant #99](https://github.com/viamin/mutant/issues/99): exact matching silently
  omits a class method hidden behind a prepended wrapper. A minimal reproduction
  confirms it; the temporary audit harness resolves the class-owned super-method
  and checks its source. No dependency change was required.

The remaining expensive authentication and fallback cases exercise different
provider payloads, lifecycle transitions and state combinations. Do not remove
those distinctions based on shared lines. Per-test fault/cost observations and
profiling the remaining execution I/O are the next deeper opportunities; a
cheaper provider-level matrix needs to prove that representative integration
checks still detect wiring failures.

The final simplicity pass reviews base `8396d1a2b` through spec source
`c3a675aff94f2f27525aca649b4344bbe5cfcff011d4b7bd9af457cf51bf43f6`.
It removes unnecessary mock return values and uses existing transaction and
bulk-fixture mechanisms; no new production abstraction, dependency or global
fixture mechanism is introduced. Changed prose retains the measurement limits
and the reason for fresh group-level user objects.

Raw logs, JSON results, tested source snapshots, launch commands and comparison
scripts are retained in `/tmp/paid-execution-scenarios-20261127/`; publication
evidence records their immutable manifest and committed revision.

Reproduce the profiled selection using the usual isolated Rails test environment:

```sh
FPROF=1 RD_PROF=1 EVENT_PROF=sql.active_record EVENT_PROF_EXAMPLES=1 \
  EVENT_PROF_TOP=40 bin/rspec spec/temporal/activities/run_agent_activity_spec.rb \
  --example-matches '\AActivities::RunAgentActivity#execute(?: |$)' --seed 24680
```
