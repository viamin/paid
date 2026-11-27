# Agent-execution test setup audit, 2026-11-27

LID Full, version 1.3.0; TEST-SUITE-011/017/031.

## Scope

The previous complete-suite timings identified `RunAgentActivity` as the largest
file: 372 examples and 127.48 seconds. This round profiles that file on base
`497ba427936270d437a8b4e6d040bf02409c0830`, preserving every example and assertion.
Application code, dependencies, callbacks, validation and tenant policy are unchanged.

The default run lookup and container reconnect mocks now apply only to execution
groups. Method-level examples construct their own scenario records when needed.
Eighteen pure routing and harness-command examples run in a companion spec outside
the persisted fixture group. The execution group's Ruby language and disabled-fallback defaults
are initialized once in its existing fixture transaction, with per-example refetch
and rollback restoring changes made by individual scenarios.

## Measurements

ARM64 devcontainer, Ruby 3.4.13, private PostgreSQL 16.15, restricted `paid` role
with neither superuser nor RLS-bypass privilege. FactoryProf, RSpecDissect and
factory EventProf are enabled for the complete-file profiles, seed 24680.
Other Paid workloads continue; this session runs the comparisons sequentially.

| Source | Examples / failures | Command wall seconds | Setup seconds | Factories |
| --- | --- | --- | --- | --- |
| Original, first run | 372 / 0 | 176.53 | 51.84 | 1,171 |
| Candidate | 372 / 0 | 84.81 | 18.53 | 993 |
| Original, subsequent control | 372 / 0 | 93.40 | 29.13 | 1,171 |
| Candidate, final file layout | 372 / 0 | 83.12 | 18.26 | 993 |

Use the subsequent original control for the conservative comparison: the candidate
is about 11% faster in the final observed trial. The first run includes substantially
more startup and execution time and overstates an attributable improvement.
These are focused profiler runs, not a whole-suite speedup claim.

The candidate removes 96 unused run creations and 82 issue creations. All other
factory counts are unchanged. Every complete-file example description is retained.
The 18 pure checks pass with seed 97531 and no factories, compared with 41 factory
creations and 2.40 seconds of example execution originally; candidate example
execution is 0.038 seconds. Startup remains part of their actual command cost.

## Fault detection and isolation

Two ordered probes change persisted defaults and cached objects, then verify the
next example receives the original defaults and fresh objects. Both pass.
Disabling the shared context's `refind` modifiers makes exactly the restoration
probe fail, while the mutation probe still executes successfully.

An explicit Mutant selection exercises all 15 naming/order/count examples against
the same 178 evil mutations and three unchanged-code controls in the three class
methods. The accepted original and final runs have identical mutation identities
and outcomes: 158 evil mutations detected, 20 existing survivors, all three
controls passing and no isolation errors. No surviving mutation is hidden by an
aggregate score. This probe takes 244.05 seconds originally and 63.51 seconds
afterward; eliminating persisted setup also reduces repeated mutation-run cost.

The harness verifies the unmutated examples in an isolated child before mutation
execution, checks the selected example count and requires all neutral controls to
pass. Exploratory probes with empty selection or polluted parent-process state
are retained as diagnostics and do not establish fault-detection coverage.

Both complete-file coverage runs pass all 372 examples with seed 97531 and cover
the same 49,272 application/library lines: no lost or gained covered lines.
Reported focused coverage is 38.39%; this slice is not the combined suite's 80%
gate. The normal CI coverage runner and gate are unchanged.

## Mutation tooling

Paid pins the MIT-licensed `viamin/mutant` fork at `c88c80827493`. Its RSpec runner
uses fail-fast selection, and saved results do not contain a complete per-test
kill matrix. [Mutant issue 96](https://github.com/viamin/mutant/issues/96) requests
bounded, opt-in individual test outcomes, stable mutation identities, durations,
provenance and explicit unknown/error states for cost-aware suite review.

No tests are deleted in this round. Equal observed mutation coverage would support
this setup refactor, not prove global Pareto optimality or semantic redundancy.

## Evidence and validation

Raw reports, original/candidate snapshots and diagnostic scripts are retained in
`/tmp/paid-pareto-20261127/`. `inputs.json` records the base and final source hashes;
`coverage-comparison.json` records line parity. Lint and coherence checks pass;
coherence retains existing repository warnings. The 24-file
`evidence-sha256.json` manifest has digest
`91cbb7086e4544ccc6eff32b17fa635be9920b8da60f5608ad0b9ee32b71f06f`.
The owned private PostgreSQL container is stopped with its data retained.

Simplicity review keeps scoped existing mocks, one-time fixture configuration
and a companion pure spec. No application helper, dependency, global fixture
default or assertion deletion is introduced. Full hosted CI is separate from
these focused acceptance results.
This devcontainer is the available acceptance environment; no production deployment
exists. The separate active development worktree is untouched.
