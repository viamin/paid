# Test performance closeout audit, 2026-11-26

LID Full, version 1.3.0; TEST-SUITE-011/017/027/028/029/030.

## Combined local result

Revision `12ca3e4c8e014adbad1df69e7fc561a18a98f8e4` combines the reviewed
execution, metrics and model fixture checkpoints on main `9acd38228`. Their
spec hashes match the separately validated files; application and dependency
files are unchanged from that main revision.

The ARM64 devcontainer run completed preparation through coverage in **949.01
seconds (15.82 minutes)**, below the initial half-time target of 2,882.59 seconds.
The concurrent test phase took 866.06 seconds; shutdown finished at 955.71 seconds.

- All 2,227 normal spec files occur exactly once across five shards.
- **31,343 unique normal examples**, zero failures/errors, five existing pending.
- **179 system examples**, zero failures/errors, one existing pending.
- All **five performance examples** pass.
- Combined coverage: **122,869 / 129,314 lines (95.01%)**; the 80% gate passes.
- Pending file/description sets match the previous full diagnostic.

All six workspaces remain clean at the frozen revision. Boot metadata confirms
non-superuser/non-bypass roles, prepared statements and INFO logging. Temporal
retains private namespaces/queues and the original unavailable endpoint.
There were no overlapping local tests, linters or commit hooks from this session.
Other Paid workloads continued; sampled one-minute load ranged from 4.54 to 9.03.
All 12 owned services were confirmed stopped, with data retained.

## Attribution

The initial original-source run took **96.09 minutes**, with eight normal and one
system failure. The same original revision on the current host took **23.21
minutes**, with five normal and one system fixture failure. Host RAM changed
from 22,068,137,984 to 29,452,181,504 bytes; ambient load also differed. An earlier
passing combined candidate took 24.83 minutes.

Environment and contention were major contributors to the initial hour-plus
runtime. These trials do **not** demonstrate a code-attributable 50% speedup.
The three focused fixture comparisons remove 240, 350 and 220 factory creations,
respectively, while preserving assertions, records needed for each scenario and
focused application-line coverage. Their scoped results must not be extrapolated
to a whole-suite percentage.

## Deterministic assignment coverage

The combined report omitted two lines previously hit in
`ConfigurationExperiments::Assign`: updating an existing assignment to another
explicit variant. Its existing test picked the first variant randomly, so it
could start on the same variant requested later and skip the update entirely.

The follow-up keeps the same example and records, starts explicitly on control,
asserts that persisted state, then requests the other variant and retains the
original record/final-state assertions. There is no application change.

- With reassignment disabled and the initial picker forced to the later variant,
  the original test incorrectly passes.
- Under the same mutation, the corrected test fails its final persisted-variant
  assertion as intended.
- All **six assignment examples pass** with seeds 24680 and 97531, coverage enabled.
  Both formerly omitted lines are covered in each run.

The 15.82-minute benchmark precedes this deterministic fixture correction. A
final combined rerun including it remains pending; do not represent the earlier
measurement as testing a later revision.

## Evidence

Raw reports, boot metadata, coverage inputs, preparation logs and resource samples:
`/tmp/paid-testprof-audit/final-combined-full/`. Its 18-file SHA-256 manifest is
`evidence-sha256.json`, digest
`1adac3ef7e0f8c436f101ddd6f46b79bd1ce10d153bb52e9a7870a81f598c81a`.
The original-source control is in `original-matched-control/`; assignment normal,
negative-control and coverage reports are in `assignment-coverage/` under the same
audit root. All benchmark data and stopped services are retained.

This devcontainer is the available system acceptance environment. There is no
production deployment. Simplicity review retains one explicit initial variant
and one initial-state assertion, with no added example, record, helper or dependency.
