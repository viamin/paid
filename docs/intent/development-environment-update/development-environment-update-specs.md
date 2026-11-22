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

- [x] **DEVELOPMENT-ENVIRONMENT-UPDATE-002** — When a lightweight update's
  trigger context or pull diff includes worker-loaded application code
  (`app/temporal/`, `app/services/`, `app/models/`, `app/jobs/`) or a
  supported runtime dependency (`config/`, `db/migrate/`, `bin/`, `lib/`,
  `Procfile*`, `Gemfile`/lockfiles, `package.json`/lockfiles), the updater
  SHALL dispatch the full graceful restart path exactly once instead of
  claiming Rails will autoload the changes in long-lived workers; when the
  changes are only docs, specs, or web-autoloaded UI/controller code, the
  updater SHALL preserve the lightweight path. The activity that spawns the
  updater SHALL classify the same file sets identically via
  `FULL_RESTART_PATTERNS`.
  *Code:* `bin/dev-update`, `app/temporal/activities/trigger_dev_environment_update_activity.rb`.
  *Test:* `spec/lib/dev_update_spec.rb`, `spec/temporal/activities/trigger_dev_environment_update_activity_spec.rb`.

- [x] **DEVELOPMENT-ENVIRONMENT-UPDATE-003** — When a full restart restores an
  Overmind-healthy environment, the updater SHALL verify effective worker
  adoption by waiting, within a bounded poll budget, for the `poll` and
  `agent` Temporal worker readiness files to report the post-update
  `git rev-parse HEAD` revision, and SHALL fail the update loudly when a
  worker is missing, reports an unknown revision, or reports a stale revision.
  Worker readiness payloads SHALL publish the booted checkout revision
  (development HEAD SHA, or `PAID_DEPLOYED_REVISION` when set) and SHALL NOT
  include secret-bearing process arguments, environment, or credential
  payloads. The verification SHALL use the existing graceful Overmind
  stop/start path and SHALL NOT force-restart active workflow/activity owners,
  widen concurrency or shutdown timeouts, or reset failed runs.
  *Code:* `bin/dev-update`, `lib/paid/worker_readiness.rb`, `bin/temporal_worker`.
  *Test:* `spec/lib/dev_update_spec.rb`, `spec/lib/paid/worker_readiness_spec.rb`.
