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

The same readiness contract has one read-only recorder consumer: the
allowlisted worker-adoption measurement. Worker processes publish their own
readiness identity — PID, boot time, raw boot revision, boot-time deployment
identity, and a periodic
heartbeat — as durable per-process-boot observations in the shared application
database. This preserves overlapping old and new instances during a rolling
deploy, and the measurement requires every fresh instance of the fixed
`poll`/`agent` roles to carry the current deployment identity. It does not
accept a host path, run a host command, or inspect process arguments,
environment, or credentials, and it never reads another role's filesystem or PID namespace. Its persisted
collection receipt is owned by the trusted-measurements boundary. The raw boot
revision remains the updater's commit-adoption contract; the recorder uses the
separate complete boot-time deployment identity so later same-HEAD source drift
cannot be accepted. The Temporal worker captures that complete identity before
Rails loads application code and compares it with a second snapshot after its
routes, activities, workflows, and worker registrations are constructed. The
first snapshot uses only Ruby standard-library behavior because Rails and
Active Support are not loaded yet in development or production. It
refuses startup before readiness publication or polling when the snapshots
differ, so a source edit during boot cannot be represented as loaded worker
code. The readiness facts remain evidence about worker adoption
only and do not attest
application-level behavior.

## Temporal Worker Quiescence Before Restart

Activity-body counts are observability only: a Temporal task can already be
reserved by a long poll before Ruby enters an activity body. The updater consumes
the public slot-supplier protocol in `TEMPORAL-ORCHESTRATION-021`. It resolves
actual worker descendants of the live supervisor entries, with PID/start-time,
workspace and launch-mode checks. Another genuine worker's marker cannot cover
the supervised process. Missing, uncovered, duplicate or changing workers defer.
One both-mode worker can cover both logical roles without double-locking its
physical admission inode.

The standalone controller closes renewal on every role before waiting for
reservation-to-release shared ownership, including unused poll and eager
reservations. Only complete exclusive ownership and an unchanged actual cohort
authorize stop. Controller lock and control-pipe descriptors never reach
restarted services. The generation remains fenced through stop, setup and new
target boot verification. Every original PID/start-time instance must be proved
gone before reopening; unknown visibility is not absence. Interrupted
acknowledged updates keep persistent requests closed and expose an explicit
recovery action for unchanged, known mixed, stopped or verified target phases.
Mixed or unknown cohorts never silently reopen.

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

`TEMPORAL-ORCHESTRATION-021` owns the SDK contract and real verification.
Unsupported legacy workers still defer automatically. Their initial adoption
requires the separate closed-producer, naturally completed owner and pinned-run
idle-control maintenance procedure in the quiescence decision. This updater
does not create that authorization, cancel an owner, reset attempts, enlarge
task or shutdown budgets, or change control queues. Pre-ACK timeout removes only
the caller's generation; pre-stop abort reopens only unchanged workers.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Failed auto-stash handling | Abort before pulling, record one `git-stash` failure, and attempt a recovery start when this update stopped Overmind | Continue to pull; pop a presumed stash; exit without recovering | A failed stash leaves no invocation-owned entry and continuing can create misleading secondary failures; leaving dev down after a pre-pull stop would strand the environment. |
| Stash ownership detection | Compare `refs/stash` before and after the push | Trust the push exit status alone | Exit 0 can mean "No local changes to save" when the tree is cleaned concurrently; only a moved ref proves this invocation created an entry. |
| Git lock handling | Surface the Git failure for operator resolution | Remove lock files automatically | The updater cannot determine whether a lock belongs to a live Git process. |
| Worker-loaded code classification | Treat `app/services/`, `app/models/`, `app/jobs/` (with `app/temporal/` and runtime dependencies) as restart-worthy on both the bash and activity pattern lists | Keep claiming Rails autoloads them; classify only `app/temporal/` | Worker processes boot Rails once and retain resolved constants; the operating evidence (#5293) shows service merges completing as "lightweight" while the pre-update workers kept serving. Controllers/views/JS/docs remain lightweight because no long-lived worker retains them. |
| Adoption proof | Compare the worker readiness payload revision to post-pull HEAD, fail-closed on mismatch/timeout/unresolvable HEAD | Trust Overmind health alone; skip verification when HEAD cannot be resolved; parse `ps` arguments or environment | Process health does not distinguish on-disk checkout from running worker code, and an unknown expected revision proves nothing about adoption; process arguments/env risk exposing secrets and are not a stable contract. |
| Restart mechanism | Existing graceful Overmind stop/start path unchanged | Force-kill active workers, widen shutdown timeouts, reset failed runs | Preserves workflow/activity ownership, replay compatibility, retained results, and bounded retry/budget policies. |
| Temporal worker quiescence | Consume the verified two-stage public SDK protocol for the actual supervisor cohort, retaining controller ownership through target boot verification; defer unsupported legacy workers | Activity-body file locks; sequential idle snapshots; shutdown as an admission fence; blocking notification callbacks; treating missing metadata as absence | Outstanding poll/eager reservations must settle before stop. Unknown identities cannot authorize replacement, and fresh target markers cannot prove the old process exited. See `TEMPORAL-ORCHESTRATION-021`. |
| Recorder source boundary | Fixed role-specific readiness observations with typed public fields | Cross-container file reads, generic file readers, or process inspection | Preserves the existing safe readiness contract without making host filesystem/process access operator-controlled, and works across the independent role containers. |
| Startup identity boundary | Snapshot before application loading and verify after worker construction | Capture only when readiness starts; reload application code after drift | A final-only snapshot can describe source newer than constants already loaded during boot; refusing the raced startup is deterministic and avoids unsafe generic reload behavior. |

## References

- `bin/dev-update`
- `bin/temporal_worker`
- `lib/paid/worker_readiness.rb`
- `app/temporal/activities/trigger_dev_environment_update_activity.rb`
- `spec/lib/dev_update_spec.rb`
- `spec/temporal/activities/trigger_dev_environment_update_activity_spec.rb`
- `spec/lib/paid/worker_readiness_spec.rb`
