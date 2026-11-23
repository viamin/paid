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

## Temporal Worker Quiescence Before Restart

Activity-body counts are observability only: a Temporal task can already be
reserved by a long poll before Ruby enters an activity body. The installed Ruby
SDK does not expose a public worker operation that closes new poll and eager
admission, accounts for already-reserved work, and acknowledges that boundary
without beginning shutdown. Therefore `bin/dev-update` defers before stopping
any ready Temporal worker and reports the missing capability. It does not infer
safety from `active_activities`, block an SDK notification callback, cancel an
owner, reset an attempt, enlarge a deadline, or alter control queue routing.

Missing readiness metadata is not itself evidence that no worker is running: a
worker can fail before it marks ready, or its flag can be removed, while the
supervisor keeps the process. The deferral therefore also applies when metadata
is missing and a running Overmind still reports Temporal worker processes. It
also applies when the control socket is absent but a same-workspace orphaned
Overmind tmux session that the stop path would force-kill still hosts a
`worker_poll`/`worker_agent` window — a missing socket cannot be quit
gracefully, so stopping it would interrupt that worker without acknowledgement.
The update proceeds without quiescence only when the supervisor state verifies
no Temporal worker will be stopped (the configured Overmind Unix control socket
is absent and no such orphaned worker-bearing session exists, or a successful
status inspection reports no `worker_poll`/`worker_agent` processes). When
status fails, a present socket must also positively reject a local connection as
stale; any other failure is unknown, not proof that no worker is running. An
orphaned session that cannot be inspected is not drained: the stop path fails
before setup on it (`RAILS-CONTROL-PLANE-019`) rather than force-killing it.

`TEMPORAL-ORCHESTRATION-019` owns the required SDK contract and rollout. Once a
released SDK implements that contract, the updater may use its acknowledged
quiescence result for both poll and agent roles, retain it through the stop
boundary, and resume normal update adoption on a timeout or abort. Until then,
the deferral is bounded and recoverable, not a claim that an idle legacy worker
is safe to stop.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Failed auto-stash handling | Abort before pulling, record one `git-stash` failure, and attempt a recovery start when this update stopped Overmind | Continue to pull; pop a presumed stash; exit without recovering | A failed stash leaves no invocation-owned entry and continuing can create misleading secondary failures; leaving dev down after a pre-pull stop would strand the environment. |
| Stash ownership detection | Compare `refs/stash` before and after the push | Trust the push exit status alone | Exit 0 can mean "No local changes to save" when the tree is cleaned concurrently; only a moved ref proves this invocation created an entry. |
| Git lock handling | Surface the Git failure for operator resolution | Remove lock files automatically | The updater cannot determine whether a lock belongs to a live Git process. |
| Worker-loaded code classification | Treat `app/services/`, `app/models/`, `app/jobs/` (with `app/temporal/` and runtime dependencies) as restart-worthy on both the bash and activity pattern lists | Keep claiming Rails autoloads them; classify only `app/temporal/` | Worker processes boot Rails once and retain resolved constants; the operating evidence (#5293) shows service merges completing as "lightweight" while the pre-update workers kept serving. Controllers/views/JS/docs remain lightweight because no long-lived worker retains them. |
| Adoption proof | Compare the worker readiness payload revision to post-pull HEAD, fail-closed on mismatch/timeout/unresolvable HEAD | Trust Overmind health alone; skip verification when HEAD cannot be resolved; parse `ps` arguments or environment | Process health does not distinguish on-disk checkout from running worker code, and an unknown expected revision proves nothing about adoption; process arguments/env risk exposing secrets and are not a stable contract. |
| Restart mechanism | Existing graceful Overmind stop/start path unchanged | Force-kill active workers, widen shutdown timeouts, reset failed runs | Preserves workflow/activity ownership, replay compatibility, retained results, and bounded retry/budget policies. |
| Temporal worker quiescence | Defer before stop when a Temporal worker is ready, when a running Overmind reports one without readiness metadata, or when a socket-less orphaned same-workspace session hosts a worker window the stop path would force-kill; consume a released public SDK quiescence capability when available | Activity-body file locks; sequential idle snapshots; shutdown; custom-slot callback blocking; treating missing readiness metadata or an absent control socket as a verified cold state | A body count cannot include a task returned by an already-reserved long poll, missing metadata cannot prove no worker owns work, and an absent control socket does not stop the tmux cleanup from killing an orphaned session's workers. Shutdown eventually cancels live owners, and custom callbacks cannot block. See `TEMPORAL-ORCHESTRATION-019`. |

## References

- `bin/dev-update`
- `bin/temporal_worker`
- `lib/paid/worker_readiness.rb`
- `app/temporal/activities/trigger_dev_environment_update_activity.rb`
- `spec/lib/dev_update_spec.rb`
- `spec/temporal/activities/trigger_dev_environment_update_activity_spec.rb`
- `spec/lib/paid/worker_readiness_spec.rb`
