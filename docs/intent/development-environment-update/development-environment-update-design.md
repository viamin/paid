---
parent: PAID
prefix: DEVELOPMENT-ENVIRONMENT-UPDATE
---

# Low-Level Design: Development Environment Update

## Purpose

`bin/dev-update` updates a local development checkout without treating local
Git state as disposable. It must leave an operator with an actionable failure
instead of continuing an update from an unknown working-tree state.

## Auto-Stash Safety

Before pulling, the updater may temporarily stash a dirty working tree. The
stash is invocation-owned state: it records that state only after `git stash
push --include-untracked` succeeds **and** `refs/stash` actually changed. Exit
status alone is insufficient because a concurrent process can clean the tree
between the dirty check and the push, leaving Git to exit 0 with "No local
changes to save" while a pre-existing `dev-update-autostash` entry still sits
at the top of the stash stack. If that command fails, the updater records one
`git-stash` failure and stops before `git pull`; it neither restores nor
alters any stash entry. In particular, it never removes a Git lock because a
lock can be owned by another Git process.

Only a stash created by the current updater invocation is eligible for the
later `git stash pop`. A failed stash attempt — or a successful push that
created no stash entry — leaves the working tree and any pre-existing
`dev-update-autostash` entries untouched.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Failed auto-stash handling | Abort before pulling and record one `git-stash` failure | Continue to pull; pop a presumed stash | A failed stash leaves no invocation-owned entry and continuing can create misleading secondary failures. |
| Stash ownership detection | Compare `refs/stash` before and after the push | Trust the push exit status alone | Exit 0 can mean "No local changes to save" when the tree is cleaned concurrently; only a moved ref proves this invocation created an entry. |
| Git lock handling | Surface the Git failure for operator resolution | Remove lock files automatically | The updater cannot determine whether a lock belongs to a live Git process. |

## References

- `bin/dev-update`
- `spec/lib/dev_update_spec.rb`
