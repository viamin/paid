# Prometheus fixture audit, 2026-11-26

LID Full, version 1.3.0; TEST-SUITE-011/017 and OBSERVABILITY-002.

The repeated-status group created seven project/account/credential graphs before
each of eleven examples. It now creates those seven graphs once through normal
factories under the existing explicit system-access setup context. TestProf's
`refind: true` array modifier supplies fresh project instances per example.

The seven projects still belong to seven distinct accounts. Each example creates
its own seven status runs and issues; extra terminal runs remain local to their
scenarios. Cache clearing, real collector queries, callbacks, validations and
transactional rollback remain enabled. All original assertions are retained.

## Measurements

FactoryProf/RSpecDissect ran the entire metrics file with seed 24680 and coverage
enabled, sequentially against fresh private databases in the ARM64 devcontainer.
Application source was identical across legs; collector SHA-256:
`51e86276f9f54d7833ff11e7181e52e08928723f34d46fe2ccbdd8ee4ba09a8b`.

| Measure | Original | Shared projects | Original control |
| --- | ---: | ---: | ---: |
| Examples / failures / pending | 38 / 0 / 0 | 38 / 0 / 0 | 38 / 0 / 0 |
| Factory creations | 717 | 367 | 717 |
| Top-level factory creations | 110 | 117 | 110 |
| Example-body seconds | 14.096 | 12.661 | 15.584 |
| Boot-through-coverage seconds | 24.059 | 22.657 | 24.793 |

All three legs have identical example IDs/descriptions and the same **44,130
covered application lines**, none lost. Each retains 98 run and 98 issue factory
calls. The file's project factories drop from 99 to 29. Top-level factory count
increases because the seven shared projects are now explicit top-level setup;
total factory work decreases by 350 creations. This scoped result does not
establish a whole-suite percentage speedup.

Two ordered isolation probes pass. They verify seven distinct accounts, stable
project IDs with fresh Ruby objects, restored project names and association
caches, rollback of previous run IDs, and restored failed/retried outcome gauges.
Disabling `refind` makes exactly the restoration example fail through an RSpec
expectation. These probes remain outside the repository.

Evidence: `/tmp/paid-testprof-audit/metrics-fixture-profile/`, including launch
metadata, raw JSON reports, profiler logs, coverage, comparison and probe results.
The timed candidate precedes a line-wrapping-only cleanup of two factory calls.
The final source passes all **38 examples, zero failures/pending**, with alternate
seed **97531**, coverage enabled and profilers disabled. This focused run does
not replace the full-suite coverage gate. Tested base revision:
`888bbbcee00aa0707f8d8456756fa99c29498755`; final spec SHA-256:
`1cc3acc92e67a208f7a8fb9f6cdc426f42e54952d9afb51c8377fbf3fd291c40`.

Simplicity review retains one scoped collection of seven explicit project
configurations. There are no global defaults, new dependencies, shared scenario
runs, callback bypasses or application changes. This devcontainer is the available
system acceptance environment; no production deployment exists.
