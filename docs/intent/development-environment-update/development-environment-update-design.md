---
parent: PAID
prefix: DEVELOPMENT-ENVIRONMENT-UPDATE
---

# Low-Level Design: Development Environment Update

## Purpose

`bin/dev-update` updates a local development checkout without treating local
Git state as disposable. It must leave an operator with an actionable failure
instead of continuing an update from an unknown working-tree state, and it must
only claim a restart-worthy change was adopted once the long-lived worker
processes provably run the updated code.

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
lock can be owned by another Git process. When the failing update had already
stopped Overmind (a migration-triggered full restart stops it before pulling),
the updater attempts a recovery start before exiting, like every other
post-stop failure path; when this invocation never stopped Overmind, the
recovery attempt is a no-op.

Only a stash created by the current updater invocation is eligible for the
later `git stash pop`. A failed stash attempt — or a successful push that
created no stash entry — leaves the working tree and any pre-existing
`dev-update-autostash` entries untouched.

## Worker-Loaded Change Classification

The dev environment runs long-lived worker processes (`worker_poll`,
`worker_agent` from the Procfile, plus the GoodJob `jobs` process) that boot
Rails once and keep the constants they loaded. A lightweight update that only
pulls cannot make those processes run new code: wrapping each activity in
`Rails.application.executor` does not reload classes a worker process already
resolved. The updater therefore treats changes to worker-loaded application
code — `app/temporal/`, `app/services/`, `app/models/`, `app/jobs/` — plus
their supported runtime dependencies (`config/`, `db/migrate/`, `bin/`, `lib/`,
`Procfile*`, `Gemfile`/lockfiles, `package.json`/lockfiles) as
restart-worthy, on both classification paths:

- `bin/dev-update#restart_required_for_file` for files observed locally
  (trigger context and pull diff).
- `Activities::TriggerDevEnvironmentUpdateActivity::FULL_RESTART_PATTERNS` for
  files reported by the GitHub API before spawning the updater.

The two pattern lists are one contract duplicated across process boundaries
(one bash, one Ruby); they must change together. Only changes that no
long-lived process retains — docs, specs, web-autoloaded controllers/views/
JavaScript/CSS — remain lightweight, and the lightweight completion message
("Rails will autoload changes") stays valid only for that reduced set.

## Effective Worker Adoption Verification

A completed restart is not proof of adoption: workers can come back healthy
while still running old code (for example, a failed checkout or a stale
process). Workers already publish readiness metadata through
`Paid::WorkerReadiness` flag files; the readiness payload includes the
checkout revision the worker booted from (HEAD SHA in development,
`PAID_DEPLOYED_REVISION` when set). The revision is a public commit identity —
the payload must never carry secrets, credential payloads, or secret-bearing
process arguments.

After a restart becomes Overmind-healthy, the updater waits (bounded polling)
for both Temporal worker readiness files (`poll` and `agent` modes under the
system tmpdir) to report the post-update `git rev-parse HEAD`. When the
updater's own `git rev-parse HEAD` fails after the restart, there is no
expected revision to compare against, so verification fails closed with an
actionable error rather than being skipped — an unverifiable adoption is not
a successful one. When a worker fails to report, reports an unknown
revision, or reports a stale revision within the budget, the updater fails
loudly instead of declaring the update complete — a silent "Rails will
autoload changes" claim is exactly the gap this closes. The restart itself
stays on the existing graceful Overmind path
(stop → setup → start), preserving active workflow/activity ownership, replay
compatibility, retained results, bounded retry/budget policies, and
control-queue routing; the updater never force-kills active owners to speed
adoption.

## Active-Work Drain Before Restart

Before a full update asks Overmind to stop, each Temporal worker reserves an
activity execution slot through a custom Temporal SDK slot supplier. The
supplier takes shared ownership of its per-worker admission barrier before
Temporal polls for the task and retains it through task release. The updater
acquires the corresponding barriers exclusively and retains both through the
stop request. This keeps a task queued while the barrier is held instead of
letting Temporal assign it and then blocking inside `BaseActivity` until its
heartbeat deadline expires. Acquiring a role's barrier waits for any existing
SDK slot reservation or running activity and then closes admission for that
role, so work cannot arrive on the first role while the updater waits for the
second. Workers continue to publish safe active counts alongside immutable boot
identity for observability; neither the barrier nor metadata contains activity
input, process arguments, environment, or credentials.

The wait has a bounded poll budget. If either ready worker remains active or
its count cannot be read within that budget, the update fails before stopping
Overmind and records that adoption was deferred. It does not turn the failed
update into a restart, cancel an owner, reset an audit, enlarge any activity or
shutdown timeout, or alter the existing control queues. A later authorized
normal full update can retry after the owners have reached their normal
terminal or handoff state.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Failed auto-stash handling | Abort before pulling, record one `git-stash` failure, and attempt a recovery start when this update stopped Overmind | Continue to pull; pop a presumed stash; exit without recovering | A failed stash leaves no invocation-owned entry and continuing can create misleading secondary failures; leaving dev down after a pre-pull stop would strand the environment. |
| Stash ownership detection | Compare `refs/stash` before and after the push | Trust the push exit status alone | Exit 0 can mean "No local changes to save" when the tree is cleaned concurrently; only a moved ref proves this invocation created an entry. |
| Git lock handling | Surface the Git failure for operator resolution | Remove lock files automatically | The updater cannot determine whether a lock belongs to a live Git process. |
| Worker-loaded code classification | Treat `app/services/`, `app/models/`, `app/jobs/` (with `app/temporal/` and runtime dependencies) as restart-worthy on both the bash and activity pattern lists | Keep claiming Rails autoloads them; classify only `app/temporal/` | Worker processes boot Rails once and retain resolved constants; the operating evidence (#5293) shows service merges completing as "lightweight" while the pre-update workers kept serving. Controllers/views/JS/docs remain lightweight because no long-lived worker retains them. |
| Adoption proof | Compare the worker readiness payload revision to post-pull HEAD, fail-closed on mismatch/timeout/unresolvable HEAD | Trust Overmind health alone; skip verification when HEAD cannot be resolved; parse `ps` arguments or environment | Process health does not distinguish on-disk checkout from running worker code, and an unknown expected revision proves nothing about adoption; process arguments/env risk exposing secrets and are not a stable contract. |
| Restart mechanism | Existing graceful Overmind stop/start path unchanged | Force-kill active workers, widen shutdown timeouts, reset failed runs | Preserves workflow/activity ownership, replay compatibility, retained results, and bounded retry/budget policies. |
| Active work during update | Acquire and retain exclusive per-worker activity-admission barriers through the stop request; have the Temporal SDK reserve activity slots under the shared barrier before polling, then use the existing graceful restart | Sequential idle snapshots; block in `BaseActivity` after task assignment; stop immediately; force a handoff; increase shutdown/activity deadlines | A retained barrier closes the arrival race between roles while pre-poll admission prevents an assigned task from spending its heartbeat budget waiting for the update fence. An immediate stop can end a live activity's heartbeat and consume its finite retry budget. |

## References

- `bin/dev-update`
- `bin/temporal_worker`
- `lib/paid/worker_readiness.rb`
- `app/temporal/activities/trigger_dev_environment_update_activity.rb`
- `spec/lib/dev_update_spec.rb`
- `spec/temporal/activities/trigger_dev_environment_update_activity_spec.rb`
- `spec/lib/paid/worker_readiness_spec.rb`
