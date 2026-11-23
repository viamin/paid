# EARS Specs: Developer Migration Guard

> Testable claims for the post-checkout migration sync boundary.

- [x] **DEVELOPER-MIGRATION-GUARD-001** — When the post-checkout hook runs
  for a trusted branch checkout between two resolvable refs whose migration
  trees differ, the hook SHALL ensure worktree databases before running
  added migrations, and SHALL keep the checkout succeeding when database
  creation fails. When no worktree suffix is derived, the hook SHALL run
  migrations without requiring worktree database creation.
  *Code:* `.githooks/post-checkout`.
  *Test:* `spec/scripts/post_checkout_hook_spec.rb`.
- [x] **DEVELOPER-MIGRATION-GUARD-002** — When the hook receives Git's null
  previous ref (all zeros or empty), as on `git worktree add --detach` or an
  initial checkout, the hook SHALL invoke no Rails command and no database
  command, SHALL print a new-worktree skip notice, and SHALL exit
  successfully (#5292).
  *Code:* `.githooks/post-checkout`.
  *Test:* `spec/scripts/post_checkout_hook_spec.rb`.
- [x] **DEVELOPER-MIGRATION-GUARD-003** — When the previous or new ref does
  not resolve, the hook SHALL NOT treat the failed revision inspection as an
  empty valid migration tree, SHALL invoke no Rails or database command,
  SHALL print a skip notice, and SHALL exit successfully (#5292).
  *Code:* `.githooks/post-checkout`.
  *Test:* `spec/scripts/post_checkout_hook_spec.rb`.
- [x] **DEVELOPER-MIGRATION-GUARD-004** — When a comparison ref resolves but
  its migration tree cannot be read, the hook SHALL skip with a notice
  instead of computing a false all-added diff, SHALL invoke no Rails or
  database command, and SHALL exit successfully (#5292).
  *Code:* `.githooks/post-checkout`.
  *Test:* `spec/scripts/post_checkout_hook_spec.rb`.
- [x] **DEVELOPER-MIGRATION-GUARD-005** — When `SKIP_MIGRATION_GUARD=1` is
  set, the hook SHALL exit immediately without invoking Rails or database
  commands.
  *Code:* `.githooks/post-checkout`.
  *Test:* `spec/scripts/post_checkout_hook_spec.rb`.
