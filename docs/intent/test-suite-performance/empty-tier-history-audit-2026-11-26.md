# Empty tier-history lookup audit: 2026-11-26

## Change and boundaries

Auto-Pick plans its full eligibility relation inside the model-selection history
query even when the project has no selections. Check project-scoped history
first; retain the original candidate-restricted lookup when history exists.
The shortcut is not cached. Candidate and dequeue guards, callbacks, validation
and tenant enforcement remain enabled (AUTO-PICK-QUEUE-011).

## Devcontainer evidence

Base: `b3d6310ce796b89dab221d0f4af138a1fa8df2c0`. Focused checks on the
changed content pass **211 examples**, zero failures or pending, seed 24680,
coverage enabled. The new empty-project query regression fails on the original
code. Its companion verifies that a newly pinned tier is observed on the next
call. Existing cases retain latest-tier, live-runner and dequeue coverage.

An alternating comparison within one process executes ten calls per block:

| Block order | Original lookup | Guarded lookup |
| --- | ---: | ---: |
| Original, guarded | 1.1960 s | 0.1104 s |
| Guarded, original | 0.9997 s | 0.1030 s |
| Original, guarded | 1.0578 s | 0.1109 s |

Both return no blocked IDs. The guarded measurement includes the cached
feasibility check; the original measurement calls the history lookup directly.
This establishes lower cost for this empty-history path, not total-suite speed.

Four separate 27-example audit profiles all pass. Original/prototype/original/
prototype example times are **76.10 / 117.48 / 87.49 / 90.14 seconds**. The first
prototype replaces 191 candidate-history queries with simple existence checks,
reducing that SQL category from 14.86 to 2.17 seconds, while unchanged SQL also
slows substantially. These runs do **not** establish a workload wall-time gain.
They use the same workspace, spec content, seed, coverage and profilers, with
fresh private PostgreSQL databases. Other Paid workloads continue on the host.

## Deeper query work

Two fixed list filters and six existing raw SQL join/guard expressions prevent
prepared-plan reuse in the candidate relation. Changing only the lists still
leaves it unpreparable; that ineffective experiment is omitted from the patch.
A broader rewrite needs separate behavior and tenant evidence. The audit also
found missing planner statistics in restored databases. Refreshing all 245
tables took 0.45 seconds; a subsequent original-source run passed 27 examples
in 92.96 seconds, providing no workload speedup evidence. No global
query-policy setting is changed.

The complete local integration diagnostic predates this change. A passing
whole-suite comparison proving the requested 50% runtime reduction is still
required. No production deployment exists.
