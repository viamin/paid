# EARS Specs: Development Environment Update

> Testable claims for safe automatic development-checkout updates.

- [x] **DEVELOPMENT-ENVIRONMENT-UPDATE-001** — When `git stash push
  --include-untracked` fails while `bin/dev-update` handles a dirty working
  tree, the updater SHALL record exactly one `git-stash` failure and stop
  before `git pull`, SHALL leave the working tree and pre-existing stash
  entries untouched, SHALL only set its stash-restoration state after a
  successful stash push, and, when this update already stopped Overmind,
  SHALL attempt a recovery start before exiting. When a successful push
  creates no stash entry (for example, the tree is cleaned concurrently and
  Git reports "No local changes to save"), the updater SHALL leave `refs/stash`
  and any pre-existing `dev-update-autostash` entry untouched and SHALL not
  attempt a restore.
  *Code:* `bin/dev-update`.
  *Test:* `spec/lib/dev_update_spec.rb`.
