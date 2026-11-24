---
parent: PAID
prefix: DEVELOPER-MIGRATION-GUARD
---

# Low-Level Design: Developer Migration Guard

## Purpose

`.githooks/post-checkout` keeps a trusted developer checkout's database in
sync when switching between real branches: it rolls back orphaned migrations
and runs pending ones, creating branch-specific worktree databases first
(`bin/ensure-worktree-databases`). The hook must never turn a mere checkout
into host-side execution of candidate Rails code or host database setup.

## Boundary

The migration comparison is only meaningful between two resolvable Git refs
with readable migration trees. Anything else is an inspection-only checkout:

- Git passes its null ref (all zeros) as the previous HEAD for new-worktree
  and initial checkouts. Acceptance/source-inspection worktrees are created
  exactly this way (`git worktree add --detach`), and the checked-out code is
  untrusted candidate code that must only execute in its isolated container.
  The hook exits before touching Rails or the database.
- A previous or new ref that does not resolve (`git rev-parse --verify
  --quiet <ref>^{commit}` fails), or a `git ls-tree` migration-tree read
  that fails, means no comparison is available. The hook skips. Treating a
  failed read as an empty tree would report every migration as added and run
  host `bin/rails db:migrate` — the #5292 incident.
- Skip messages are printed so the developer can see why the guard did not
  run; the checkout itself always succeeds.

## Trusted path

Deliberate branch switching in a developer checkout keeps the documented
behavior: compute removed/added migration sets with `comm`, ensure worktree
databases when a suffix is derived, roll back removed migrations (restoring
their files from the previous ref only for the rollback), and run
`bin/rails db:migrate` for added ones. `SKIP_MIGRATION_GUARD=1` remains the
explicit opt-out, and file checkouts (flag `0`) never trigger the guard.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| New-worktree / null previous ref | Exit before any Rails or database command | Treat null ref as empty tree and migrate | Worktree checkouts are frequently candidate code staged for inspection; checkout must not execute it or mutate host databases (#5292). |
| Unresolvable ref or unreadable tree | Print skip reason and exit 0 | Silently diff against empty output | A failed tree read is missing information, not an empty migration set; the false all-added diff is what triggered host database setup. |
| Trusted branch switch | Preserve ensure-worktree-databases + migrate | Disable the hook globally | Documented developer setup, hooks and checks stay intact; only the inspection boundary changes. |
| Cleanup of incident databases | Out of scope for the hook | Auto-delete suffixed worktree databases | Hiding the incident's side effects is worse than leaving them; cleanup is a separate operator decision. |

## References

- `.githooks/post-checkout`
- `bin/ensure-worktree-databases`
- `config/worktree_database_names.rb`
- `spec/scripts/post_checkout_hook_spec.rb`
