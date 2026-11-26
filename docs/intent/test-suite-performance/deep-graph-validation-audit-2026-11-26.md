# Deep-graph validation audit: 2026-11-26

## Finding and change

The maximum-depth root-ranking example creates 500 issues and 499 dependency
edges through normal factories. Its 727.76-second result in the concurrent
integration diagnostic does not reproduce in isolation: the original passes
in 48.32 seconds, with 13.78 seconds creating issues and 28.84 seconds creating
edges. Ranking and remaining assertions take about 5.70 seconds.

Leaf-first construction already avoids walking a growing ancestor path, but
each edge still reloads the account-wide cycle graph. After acquiring the
existing account transaction lock, a distinct target with no outgoing
persisted declarations cannot lead back to its dependent. Return the existing
no-cycle result in that case. Self references and non-leaf targets retain the
full local and resolved-external graph check (DEPENDENCY-DECLARATIONS-008).
No factory callback, validation, tenant rule, graph-depth limit or assertion is
removed; the 500-node regression remains unchanged.

## Focused comparison

Base: `088588d223cbabf30e5d7eb1e93e7357f7e6c429`. All three runs use the same
workspace, example, seed 24680, coverage, FactoryProf, RSpecDissect and stage
timers, with fresh private PostgreSQL databases and normal tenant enforcement.
The repeated control loads the original cycle-check method from that revision.
Other Paid workloads remain active.

| Source | Example | Issue setup | Edge setup | Edge-setup SQL calls |
| --- | ---: | ---: | ---: | ---: |
| Original | 48.32 s | 13.78 s | 28.84 s | 4,491 |
| Leaf check | 43.21 s | 16.90 s | 20.12 s | 3,493 |
| Original control | 77.69 s | 33.58 s | 37.13 s | 4,491 |

Every run passes and retains all 500 issue and 499 edge factories. The change
removes 998 graph-query calls. Elapsed times vary, including unchanged issue
setup, so this sequence does not establish a general percentage speedup.
A separate copy of the retained full-run database passes in 96.83 seconds.
Its policies and tenant helper definitions match the fresh database; database
state and host contention remain separate investigation questions.

## Verification

The focused model, dependency parser, cycle and root-ranking files pass
177 examples with zero failures or pending. The new leaf-query regression
fails on the original implementation. Under an explicit tenant context, a
separate PostgreSQL session cannot acquire the writer's account lock.
The external-self-reference regression retains the exact cycle diagnostic.
Moving the lock below the shortcut makes the lock regression fail on an
unlocked competing session. Dropping the distinct-target condition makes the
external-self-reference regression fail. Both temporary mutations are outside
the repository; no unsafe variant is retained.

A complete passing local comparison proving the requested 50% suite-runtime
reduction remains outstanding. No production deployment exists.
