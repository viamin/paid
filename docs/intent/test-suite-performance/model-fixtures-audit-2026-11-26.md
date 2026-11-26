# AgentRun fixture audit, 2026-11-26

LID Full, version 1.3.0; TEST-SUITE-011/017.

Nine reviewed scopes reuse the existing transactional `with stable project`
context: retry priority, PR planning lookup, broadcast and dispatch callbacks,
synthetic finish/visibility, two counter-cache groups and execution-usage scopes.
Counter sharing stays within its two child groups; the now-unused parent project
definition is removed. Unrelated workspace cases retain their lazy run setup.

Runs, issues and usage records remain per example. Customized actor, TDD,
priority-label and cross-project fixtures are unchanged. The single-example
ten-tier fixture remains local. All existing assertions and examples are retained;
no callback, validation or tenant constraint is disabled.

## Matched measurements

The entire 687-case model file ran sequentially against fresh private databases
with FactoryProf, RSpecDissect and per-example factory EventProf, seed 24680 and
coverage enabled. All legs use application source from
`9acd382289bb3f7b55119e28640c94ef138afa02` after the dependency fix merged.

| Measure | Original | Shared projects | Original control |
| --- | ---: | ---: | ---: |
| Examples / failures / pending | 687 / 0 / 0 | 687 / 0 / 0 | 687 / 0 / 0 |
| Factory creations | 3,900 | 3,680 | 3,900 |
| Top-level factories | 1,006 | 962 | 1,006 |
| Project factories | 531 | 487 | 531 |
| Example-body seconds | 72.322 | 69.773 | 71.774 |
| Boot-through-coverage seconds | 80.239 | 79.576 | 79.530 |

Each leg retains **583 run and 594 issue creations**, identical example
IDs/descriptions, and the same **47,091 covered application lines**, none lost.
The change removes 44 repeated configuration graphs and 220 factory creations.
The example-time reduction is modest; process wall time matches the original
control. This does not demonstrate a repeatable end-to-end or whole-suite speedup.

## Isolation

Eighteen ordered probes pass across all nine scopes. They verify stable project
IDs with fresh model/actor objects, restored names, counters, timestamps and
association caches, unchanged credentials, and rollback of previous run IDs.
Disabling refind makes exactly the nine restoration probes fail through RSpec
expectations. Probe files stay outside the repository.

The execution-usage parent setup creates three runs. An original-source diagnostic
confirms their callbacks touch the database timestamp without updating the Ruby
project timestamp. Restoration probes compare the normal post-setup Ruby state
and separately reject the injected persisted timestamp. The initial probe's
incorrect timestamp assumption and failure report are retained; application
timestamp behavior is unchanged.

Evidence: `/tmp/paid-testprof-audit/agent-run-factory-profile/`, including raw
reports, source hashes, profiler logs, coverage, comparison and probe results.
The timed candidate precedes deletion of the unused parent fixture definition;
the final source passes **687 examples, zero failures/pending**, with alternate
seed **97531**, coverage enabled and profilers disabled. Final spec SHA-256:
`ec73020d2541bcab94d75b15e8230ba9d93f1397237c3773f00ae1f119fcb9ec`.
These focused runs do not replace the full-suite coverage gate. Other Paid
workloads continued running during the measurements.

Simplicity review retains nine inclusions of an existing context, with no new
helper, dependency, global defaults or application change. The ARM64 devcontainer
is the available acceptance environment; no production deployment exists.
