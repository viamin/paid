---
parent: PAID
prefix: PR-BRANCH-PUBLISH
---

# Low-Level Design: PR Branch Publish Integrity

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment owns the git-level safety of pushing an agent run's work onto a
> remote branch — specifically, what a push is allowed to assume about the
> remote state it is about to overwrite. `container-runtime` owns container
> lifecycle and provisioning; this segment owns the publish step itself,
> `Containers::GitOperations#push_existing_pr_branch` and
> `#push_force_with_lease`.

## Purpose

An agent run that works an existing PR branch checks it out once, at the
start of the run, and then — possibly hours later, after the agent has made
its own commits — pushes its result back onto that same branch name. Between
checkout and push, the remote branch is not read-only: a human collaborator,
a different agent run resolving the same PR, or a parallel follow-up run can
push their own commits to it. Git's `--force-with-lease` exists precisely to
make this safe — a lease push only succeeds if the remote still matches an
expected SHA, so a concurrent change causes the push to be rejected rather
than silently overwritten.

That protection only holds if the "expected SHA" is a value from *before* the
unknown concurrent change could have happened. The run has to decide, once,
which remote state it is entitled to overwrite — and then hold that decision
immutable until it is genuinely superseded by its own verified work (a clean
rebase). If a push instead re-fetches the remote branch and feeds that fresh
value back into the same push's lease, the lease can never fail: it is always
comparing the remote against itself at the moment of comparison. Any commit
that landed before that fetch — including one representing real, reviewed
work — becomes invisible to the lease and is silently replaced. This is a
non-fast-forward lost update wearing the lease's protective syntax without
its protective effect, and it is the mechanism behind the November 19
incident (see `docs/intent/README.md` conventions; incident detail lives in
the owning issue/PR history, not reproduced here as it is session-specific).

## Expected remote head

Each existing-PR agent run binds one **expected remote head**: the exact SHA
of the branch tip it is entitled to overwrite. It is derived, never
re-derived from a live fetch at push time:

1. **Admission value** — `AgentRun#expected_remote_head_sha`, captured once
   by `GitOperations#clone_and_checkout_branch` immediately after checking
   out the remote branch, before the agent makes any commits. This is the
   actual PR tip the run started from — not `base_commit_sha` (merge-base
   with the default branch, used for diff/review framing) and not a value
   re-read later. Write-once: a retried checkout (same Temporal activity
   attempt restarting before any push) does not overwrite an
   already-recorded value.
2. **Superseding value** — `AgentRun#result_commit_sha`, the SHA this run
   itself last successfully published to that exact branch. Once a run has
   pushed, it has verified (by successfully rebasing or pushing) that this
   SHA is safe to be the new baseline, so it takes priority over the
   admission value for any later push by the same run (e.g. the rebase-driven
   republish `push_force_with_lease` performs after conflict resolution).

`GitOperations#expected_remote_head_for_publish` resolves these in that
priority order. When neither identity exists, publication is held without a
network mutation. The local result remains recorded for reconciliation in a
fresh run that captures the current remote head; a live fetch cannot grant a
legacy run authority to overwrite concurrent work. A push's `--force-with-lease` always uses this value, never a
value read fresh from `git fetch` immediately before the push.

## Publish flow

```
push_existing_pr_branch
  expected = expected_remote_head_for_publish
  push --force-with-lease=branch:expected
  ├─ accepted  → remote still matched `expected`; done (ordinary
  │              fast-forward publish, or a race precisely avoided)
  └─ rejected (stale info) → remote has moved past `expected`
       unshallow + fetch branch → actual = current remote tip
       git rebase origin/branch
       ├─ conflict → abort rebase, raise PushError (nothing pushed,
       │             nothing local is discarded; the run's commits and
       │             the remote's commits both still exist, untouched)
       └─ clean    → rebase replayed this run's commits on top of
                      `actual`, so every commit reachable from `actual`
                      remains an ancestor of the result
            push --force-with-lease=branch:actual
            ├─ accepted → published; `actual`'s commits preserved
            └─ rejected (stale info again) → a second concurrent push
                         landed between the fetch above and this push;
                         raise PushError describing the changed head.
                         Bounded: this is the one recovery attempt, not
                         a loop. The run's commits stay in the container,
                         ready for the next attempt (Temporal retry or
                         manual replay) to resolve against whatever the
                         remote is by then.
```

The same `expected_remote_head_for_publish` substitution applies to
`push_force_with_lease`, used by `Conflicts::Resolve` to republish a branch
after an auto-rebase onto a sibling run's branch. It has no second-attempt
recovery of its own: a stale-info rejection there raises `PushError`, which
`Conflicts::Resolve#push_rebased_branch` already catches and turns into a
`manual` resolution outcome — an existing, actionable hold, not a new retry
loop.

Either way, a push never fabricates success: a rejected lease, a conflicted
rebase, or a second rejected lease all raise `PushError` with the git stderr
(and, for the changed-head cases, an explicit statement of what moved) rather
than returning as if the push had landed.

Before either publication route performs its network mutation, it records the
current local HEAD in `AgentRun#unpublished_result_commit_sha`. This remains
available in existing run records when Git rejects publication, giving the
existing failure surfaces an exact revision for replay or manual recovery.
`result_commit_sha` continues to mean a successfully published revision; on
success it is set to the final HEAD (which can differ after recovery rebase)
and the unpublished value is cleared.

## Why this preserves intervening commits

The property this segment exists to guarantee: once a commit is on the
remote branch, no later push by any run can remove it from history unless
that run's own commits are rebased on top of it first. `--force-with-lease`
against the immutable expected head makes the remote's actual state and the
run's belief about that state converge at the moment of the atomic git
push — a concurrent writer is only ever discovered by rejection, never
silently absorbed by re-reading the value being checked against. The existing
rebase-and-retry recovery (already present before this change) is what turns
that rejection into a preserved outcome: rebase replays the run's commits
*onto* the newer tip, so the newer tip's commits are ancestors of whatever
gets pushed next.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
|---|---|---|---|
| Source of the lease's expected SHA | Immutable per-run value (`expected_remote_head_sha` / `result_commit_sha`), never a value from a fetch issued by the same push attempt | Fresh `git fetch` + `rev-parse` immediately before each push (prior behavior) | The prior approach can never detect a concurrent change that landed before its own fetch — it always reports the remote as matching itself. An immutable value captured at admission is the only value that predates every possible concurrent writer during this run's working window. |
| Where the admission value is captured | `clone_and_checkout_branch`, right after checkout, before any commit | Deriving it from `base_commit_sha` (merge-base with default branch) | `base_commit_sha` is explicitly the merge-base, not the PR tip — a long-lived PR branch diverges from the default branch, so merge-base understates how much of the branch's own history the run is entitled to overwrite. Using it as the lease SHA would make `--force-with-lease` reject (or silently mismatch) even the common, uncontested case. |
| Idempotency of the admission capture | Write-once capture: a retried checkout of the same run does not overwrite a previously recorded value | Re-capture on every checkout attempt | `clone_and_checkout_branch` can be retried by Temporal before any push happens. Re-capturing on every attempt is only a problem if a retry's local HEAD can differ from the first attempt's (it currently cannot, since no commits have been made yet), but pinning it write-once removes the dependency on that invariant and keeps the "admission" value meaning what its name says even if the checkout path grows a case where it can differ. |
| Recovery depth for `push_existing_pr_branch` | One rebase-and-retry attempt; a second rejection raises | An unbounded retry loop until the lease succeeds | The acceptance criteria explicitly rule out an unbounded retry loop. A second rejection means a second concurrent writer raced the first recovery; surfacing it (rather than looping) keeps the failure visible and keeps token/compute spend bounded. The run's commits are not discarded, so a subsequent Temporal retry or manual replay can still resolve it. |
| Recovery depth for `push_force_with_lease` | None added; a stale-info rejection raises `PushError` as before | Add the same rebase-and-retry recovery as `push_existing_pr_branch` | This path already runs after an explicit rebase onto a *different* branch (the sibling run's branch, for conflict resolution) chosen by its caller. There is no well-defined "rebase onto the newer tip of my own branch" step to insert without redesigning `Conflicts::Resolve`'s rebase target, and the caller already converts the raised error into an actionable `manual` hold. Only the lease's expected-SHA source needed to change to close the lost-update gap on this route. |
| Runs without either trustworthy head identity | Hold publication and retain the exact local result for fresh-run reconciliation | Fetch the current head and use it as a force-push lease | A real isolated Git acceptance case showed the fallback overwriting a concurrent contributor commit while reporting success. Missing admission identity cannot grant overwrite authority; preserving both results takes precedence over silent publication. |

## Open Questions & Future Decisions

### Deferred

1. Whether a clean rebase during recovery should also re-run the project's
   test/lint hooks before the retry push ("fresh validation" in the fuller
   sense). Today "verified" means "rebased without conflict," matching prior
   behavior; re-running tests post-rebase is a larger, separate change to the
   push pipeline and is not required to close the lost-update gap this
   segment addresses.

## References

- `app/services/containers/git_operations.rb` — `push_existing_pr_branch`,
  `push_force_with_lease`, `clone_and_checkout_branch`,
  `expected_remote_head_for_publish`.
- `app/services/conflicts/resolve.rb` — the conflict-rebase publish route.
- `spec/services/containers/git_operations_spec.rb`.
