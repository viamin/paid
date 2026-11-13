# EARS Specs: Development Environment Update

> Testable claims for safe automatic development-checkout updates.

- [x] **DEVELOPMENT-ENVIRONMENT-UPDATE-001** — When `git stash push
  --include-untracked` fails while `bin/dev-update` handles a dirty working
  tree, the updater SHALL record exactly one `git-stash` failure and stop
  before `git pull`, SHALL leave the working tree and pre-existing stash
  entries untouched, and SHALL only set its stash-restoration state after a
  successful stash push.
  *Code:* `bin/dev-update`.
  *Test:* `spec/lib/dev_update_spec.rb`.
