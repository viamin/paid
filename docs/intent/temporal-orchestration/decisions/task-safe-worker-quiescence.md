---
node: temporal-orchestration
---

# Decision: Require a public worker quiescence acknowledgement

## Context

An updater must replace a worker without allowing a task already returned from
a long poll to consume its original finite attempt while waiting behind an
application-level fence. It must also preserve any task admitted through an
enabled eager path. A source-only audit of the official temporalio Ruby SDK
1.11.0 tagged gem — the latest published release at audit time, with the same
boundary as the pinned 1.9.0 — confirms that the inspected public Worker,
Tuner, and poller interfaces do not provide a task-safe pause-and-drain
lifecycle operation.

## Audited upstream capability (source-only)

The evidence below is a source audit of the official `temporalio` 1.11.0
tagged gem only; no 1.11.0 execution experiment was performed or claimed.

- `lib/temporalio/worker.rb` — the public worker lifecycle is still
  `run`/`run_all` (plus hot `client=` replacement for credentials). Documented
  shutdown "immediately stops accepting new work" and then, "after an optional
  grace period, all activities are canceled" before the call returns; it emits
  no admission-fence acknowledgement and is not reversible.
  `_initiate_shutdown`/`_wait_all_complete` are `@!visibility private` bridge
  internals, outside the supported boundary.
- `lib/temporalio/worker/tuner.rb` — `SlotSupplier::Custom` still exposes
  `reserve_slot` (may block, must yield a permit; the given cancellation only
  stops the reservation request), `try_reserve_slot` (must return
  immediately), and `mark_slot_used`/`release_slot`, each documented as
  "should never block, this should return immediately" and invoked on the
  shared worker reactor thread with raised exceptions ignored. `mark_slot_used`
  notifies the supplier that a reserved slot is actually used; it does not
  atomically close admission or acknowledge settlement of earlier outstanding
  poll reservations and eager responses. Therefore these callbacks cannot
  acknowledge quiescence.
- `lib/temporalio/worker/poller_behavior.rb` — new since 1.9.0:
  `PollerBehavior::SimpleMaximum`/`Autoscaling` only bound how many concurrent
  long polls scale; polling still requires an available slot first and the
  behavior reports nothing about outstanding reservations. Release and
  shutdown fixes between 1.9.0 and 1.11.0 do not add the missing contract.

## Decision Elements

- **Gate — task safety:** the operation must atomically close new poll and
  eager admission, account for outstanding unused reservations, and preserve
  each boundary task's existing attempt/deadline.
- **Gate — supported boundary:** Paid may call only released public SDK APIs;
  bridge internals and callback blocking are excluded.
- **Major — recoverability:** timeout, abort, or unknown state must leave a
  resumable admission state without cancelling existing owners.
- **Major — rollout coverage:** the contract must apply independently to poll
  and agent workers, including replacement and legacy-worker detection; until
  it ships, missing readiness metadata defers like a ready worker unless the
  supervisor state itself verifies that no Temporal worker will be stopped.

## Options in the Domain

### Activity-body file locks

**Description:** take a shared process lock on Ruby activity entry and retain
an exclusive lock in the updater before shutdown.

- **eliminated — task safety:** activity entry occurs after SDK reservation and
  assignment, so a task can have already spent its sole attempt.
- **strong — recoverability:** a file descriptor can be released after a local
  abort, but that does not repair the reservation race.

### Custom slot supplier coordination

**Description:** use `reserve_slot`, `mark_slot_used`, and `release_slot` to
hold or transfer an application-level permit during draining.

- **eliminated — task safety:** unused reservations and task arrival race with
  permit transfer are not covered by an atomic public worker acknowledgement.
- **eliminated — supported boundary:** `mark_slot_used` and `release_slot`
  must return immediately, excluding a blocking drain fence in those callbacks.

### Worker shutdown

**Description:** invoke the existing public shutdown lifecycle and allow its
grace period to finish work.

- **eliminated — recoverability:** shutdown eventually cancels live activity
  owners and cannot represent a reversible admission pause.
- **weak — rollout coverage:** it provides no acknowledgement for unused
  reservations or eager admission before stop.

### Released SDK quiescence lifecycle

**Description:** consume a public worker operation with this minimum contract:

1. `quiesce_admission` atomically stops new activity/workflow polls and every
   enabled eager admission path for that worker role.
2. Its success acknowledgement is emitted only after all polls that had a
   reservation before the fence are either cancelled without receiving a task,
   returned safely to the service queue, or represented as tracked owners.
3. The acknowledgement exposes a bounded owner count/status without task input
   or credential data; it never waits in SDK notification callbacks.
4. `resume_admission` is idempotent after a timeout or aborted replacement;
   shutdown remains a separate operation after acknowledged quiescence and
   owner drain.

- **passes — task safety:** the acknowledgement defines the missing atomic
  boundary and preserves original task budgets.
- **passes — supported boundary:** the operation is a released public API.
- **passes — recoverability:** explicit resume supports aborted drains.
- **strong — rollout coverage:** version/capability detection can defer old
  workers and admit the new protocol role by role.

## Selection

Paid defers updates before stopping ready legacy workers and requires the
released SDK quiescence lifecycle before enabling admission closure. Missing
readiness metadata is treated the same way: a worker that failed before
`mark_ready!` (or whose flag was removed) can still own or have reserved work,
so the updater defers unless the supervisor state itself verifies that no
Temporal worker will be stopped — the configured Unix control socket is absent,
or a successful running-Overmind inspection reports no
`worker_poll`/`worker_agent` processes. When inspection fails, only a present
socket that positively refuses a local connection is stale; every other failed
inspection is unknown rather than proof of worker absence. This protects
finite-attempt tasks over updater availability: a deferred update is
actionable and recoverable, while an assign-then-block race can irreversibly
consume work. The consuming change must pin the first containing SDK release
through `docs/intent/toolchain-pin-management/`, add real SDK/server controls
for ordinary, pre-fenced, idle, stale-reservation, eager, running-owner,
abort/retry, replacement, and legacy cases, and only then replace the legacy
guard in `bin/dev-update`.
