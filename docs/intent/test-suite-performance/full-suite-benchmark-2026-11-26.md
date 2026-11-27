# Full RSpec benchmark, 2026-11-26

LID: Full, version 1.3.0. TEST-SUITE-011/017 retain fixture isolation;
TEST-SUITE-029 owns the startup-budget clock regression.

## Passing candidate

Revision `0c85e5820364e76ed6a5be521fddbb4f4965418f` completed in the
ARM64 devcontainer from 20:17:39 to 20:42:29 UTC. This is the available
system acceptance environment; no production deployment exists.

| Stage | Examples | Failures | Pending | Wall seconds |
| --- | ---: | ---: | ---: | ---: |
| Normal shard 0 | 6,146 | 0 | 0 | 1,147.47 |
| Normal shard 1 | 6,227 | 0 | 0 | 1,342.98 |
| Normal shard 2 | 6,347 | 0 | 0 | 1,199.73 |
| Normal shard 3 | 6,115 | 0 | 4 | 1,378.88 |
| Normal shard 4 | 6,508 | 0 | 1 | 1,232.22 |
| Concurrent system suite | 179 | 0 | 1 | 239.66 |
| Subsequent performance suite | 5 | 0 | 0 | 8.36 |
| Subsequent coverage collation | — | — | — | 3.03 |

The normal total is **31,343 examples, zero failures, five pending**.
Combined application coverage is **122,871 / 129,314 lines (95.01%)**;
the existing 80% gate passed. Pending descriptions and file paths match the
previous full diagnostic, including the system suite's existing pending case.

The five normal shards and entire system suite ran concurrently. The test phase
took **1,378.89 seconds**. Preparation through coverage took **1,489.83 seconds
(24.83 minutes)**; including service shutdown took 1,495.99 seconds. All 12 owned
PostgreSQL/Qdrant services were confirmed stopped, with data retained.

The manifest verifies that all **2,227 normal spec files** occur exactly once
across the five existing byte-weight partitions. System and performance specs
retain their separate stages. Installed dependencies and cached images were
warm; checkout and dependency downloads were outside the measured interval.
The source, dependencies and test options remained frozen during measurement.
This session ran no overlapping local tests, linters or commit hooks.

Each worker used its own workspace, database and Qdrant service. Boot records
verify non-superuser/non-bypass roles, prepared statements and INFO logging.
Temporal used private namespaces/queues and the verified unavailable
`localhost:7233` endpoint, matching the original benchmark's service condition.
Existing Paid workloads continued running. This measures RSpec, not every CI
workflow.

## Comparison limits

The original revision `a8c8317e9180a81cb21c71bc4654ed2eafca0139` took
**5,765.18 seconds (96.09 minutes)** through coverage. It had 31,284 normal
examples with eight failures, 179 system examples with one failure, five passing
performance examples, and 95.0% coverage. Additions and consolidations mean the
candidate and original do not have identical example IDs.

The candidate is below the absolute half-time target of **2,882.59 seconds**.
This comparison alone does not attribute the reduction to code: host RAM changed
from 22,068,137,984 to 29,452,181,504 bytes, and ambient load differed. The
candidate's sampled one-minute load ranged from 5.51 to 19.59; the original
reported 14.38 to 37.28.

The original-source control on the current host completed in **1,392.32 seconds
(23.21 minutes)** through coverage; its concurrent test phase took 1,300.29
seconds. It retained the original DEBUG logging and disabled prepared statements,
used the same host boot and RAM as the candidate, and had sampled load from
3.49 to 14.20. All 31,284 normal examples ran: five failed and five were pending.
The 179 system examples had one failure and one pending; all five performance
examples passed. Coverage was 122,660 / 129,113 lines (95.00%).

All five normal failures originate from the existing clarifying-question unit
fixture reaching its unstubbed private Qdrant URL; one wraps that failure in an
unmet expected exception. The system failure is the inbox filter fixture's nil
issue ID. These failures are retained as original-source results, not acceptance
passes. All 12 control services were confirmed stopped with data retained.

The same original revision falling from 96.09 to 23.21 minutes shows that
environment and contention were major contributors to the initial slow run.
The candidate's 24.83 minutes does **not demonstrate a whole-suite source
speedup**, much less a halving. The differing ambient load and single trials also
prevent attributing the observed candidate slowdown to code. Focused improvements
need their own before/after controls; the whole-suite code-attributable 50% goal
remains unproven.

## Execution-fixture follow-up

The execution-fixture change on this branch is **not included in the full-run
results above**. It reuses the existing `with stable project` context only for
the 49 `Containers::Provision#execute` cases. Each still creates its own run and
issue, provisions its container, and keeps credential/filesystem setup local.
Other groups retain their existing setup. No assertions or examples were removed.

FactoryProf/RSpecDissect comparisons used seed 24680, coverage enabled, a fresh
private database for each leg, and unchanged application source:

| Measure | Original | Shared project | Original control |
| --- | ---: | ---: | ---: |
| Examples / failures | 49 / 0 | 49 / 0 | 49 / 0 |
| Factory creations | 343 | 103 | 343 |
| Top-level factory creations | 98 | 50 | 98 |
| Example-body seconds | 9.279 | 7.688 | 9.341 |
| Boot-through-coverage seconds | 18.334 | 16.759 | 17.348 |

All three runs have identical example IDs/descriptions and the same **44,958
covered application lines**, with none lost. The shared-project leg retains
49 run and 49 issue factory calls; project/account/credential graphs drop from
49 to one. This is a modest scoped improvement, not a whole-suite speedup claim.

Two ordered isolation probes pass: project identity is stable but its Ruby
instance is fresh, mutations and the prior run roll back, association caches
refresh, and `agent_run.project` retains per-example identity. Disabling `refind`
makes exactly the restoration probe fail via an RSpec expectation. These
temporary probes remain outside the repository.

The entire provisioning file passes with alternate seed **97531: 384 examples,
zero failures or pending**, coverage enabled and profilers disabled. This focused
run does not replace the full-suite coverage gate. The validated spec SHA-256 is
`fc285f23a46f9bf0b1285ba465b6ab939e7a0c6a342de3e1a0e47e91deb188a1`
on base revision `0c85e5820364e76ed6a5be521fddbb4f4965418f`.

Simplicity review retains one existing context inclusion, with no new helper,
dependency, global factory default, callback bypass or application change.
Focused evidence is in `/tmp/paid-testprof-audit/execution-fixture-profile/`.

## Evidence

Retained artifacts: `/tmp/paid-testprof-audit/candidate-full-clean/`, including
five raw RSpec reports, system/performance reports, worker boot metadata,
unnormalized coverage files, preparation logs and resource samples. Coverage
paths from the five workspaces were normalized only for collation; raw inputs
remain intact.

- `inputs.json` SHA-256:
  `eefc3968fe55d2019392c68290d453740cbd60a0e1176ffb6760daacb3bf2cc3`
- `state.json` SHA-256:
  `e2679ad3713b637b793189a9efca8ba2ceec1122738e9deca4497cb346d8b54a`
- `evidence-sha256.json` SHA-256:
  `fdbbef1aa9e4d020e783eef2fd24ba4cbc4f842507ea2edf9d5f8aebbe5c3b5d`

The evidence manifest hashes each report, raw coverage input, driver, partition
manifest and seed file. The original control uses
`/tmp/paid-testprof-audit/original-matched-control/`; its source workspaces and
services are separate, and it started after all candidate services stopped.
