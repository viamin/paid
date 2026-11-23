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

## Local SDK/Core proposal (not an operating dependency)

This is a version-bound local proposal for `temporalio` 1.11.0 and the
`sdk-core` revision it vendors, `c675c32469af707e1c979a7b808c70b4a0608b82`.
It is not implemented by that release, is not an API that Paid calls, and
must not be used to justify a worker stop. Its purpose is to give an SDK
maintainer a reviewable public contract and identify the exact Core boundary
that would need an implementation.

### Proposed public Ruby API

```ruby
future = worker.quiesce_admission
result = future.await(timeout: quiescence_deadline)

# result.state is :quiesced only after the SDK has settled every pre-fence
# poll and eager reservation. result.active_owners is a count only.
worker.resume_admission if replacement_aborted

# Proposed new API, used only by Paid's update-adoption sequence:
worker.shutdown if result.state == :quiesced && result.active_owners.zero?
```

`quiesce_admission` returns a future/promise rather than running in a tuner
callback. Its caller performs a bounded `await` before inspecting `result.state`.
It resolves to one of:

- `:quiesced`, with a non-negative `active_owners` count, only after the
  acknowledgement conditions below hold;
- `:unsupported`, when the installed Core cannot provide the operation;
- `:unknown`, `:timed_out`, or `:failed`, none of which authorize shutdown.

`resume_admission` is idempotent for every non-shutdown outcome. It reopens
only the role's admission gate; it neither reissues a task nor creates an
attempt. The `shutdown` call in the example is a proposed new public API, not
a method provided by Ruby SDK 1.11.0. That release exposes `run`/`run_all`
with cancellation or shutdown signals; their existing ordinary shutdown
semantics remain unchanged. The proposed terminal operation is only an
update-adoption sequence: its caller must first receive `:quiesced` and make
its own owner-drain decision. Neither proposed method exposes task payloads,
tokens, credentials, or customer data.

The result must not be derived from `SlotSupplier::Custom#mark_slot_used`.
That callback does observe that a reserved slot became used, but it cannot
atomically close admission or account for reservations that were already
outstanding when an updater began. The callbacks must continue to return
immediately.

### Required Core operation

Core needs a per-worker, generation-scoped admission state distinct from its
terminal shutdown token:

1. Atomically move the worker from `open` to `quiescing` before starting any
   cancellation or unregister operation. New activity, workflow, sticky, local
   activity, Nexus, and eager admission attempts observe that gate and do not
   obtain a new reservation.
2. Register every pre-fence poll RPC, slot reservation, eager reservation, and
   task returned from a poll before it crosses the language bridge. A returned
   task is either delivered as a tracked owner with its original token,
   attempt, and deadline, or settled without delivery through the service/Core
   path that preserves its original retry semantics.
3. Close eager sources at the same fence and unregister the eager slot provider
   as one settlement participant, not as proof that already-offered eager work
   is absent.
4. Resolve `quiesce_admission` only after the pre-fence set is empty or every
   member has become a tracked owner. Report the owner count without waiting in
   any language callback. A cancelled poll alone is not acknowledgement that
   it did not concurrently return a task.
5. Permit `resume_admission` only while the worker is not terminally shutting
   down. It discards the old generation after its members are settled, then
   allows new polls/reservations in a new generation.

The relevant current Core boundary is `Worker::initiate_shutdown` in
`crates/sdk-core/src/worker/mod.rs`: it cancels the terminal shutdown token,
unregisters eager workflow start, and invokes activity shutdown. The activity
manager then closes its eager semaphore in
`crates/sdk-core/src/worker/activities.rs`. Those operations are irreversible
shutdown mechanics; they do not retain a resumable admission generation or
return an acknowledgement for a concurrently returned poll response. A
prototype therefore belongs in Core's worker, activity-manager, workflow
stream, and C bridge surfaces, with matching Ruby bridge and public `Worker`
methods. A Ruby-only wrapper would cross the unsupported private bridge and
cannot close the race.

### Prototype and lifecycle harness boundary

No local Core/Ruby patch was created from this audit. The inspected 1.11.0
source has no admission-generation state, settlement counter, or bridge
operation on which a small Ruby-only patch could build. Implementing only the
Ruby method would make an unsupported claim; implementing it over
`_initiate_shutdown` would make abort/resume impossible. The concrete first
prototype is therefore a Core change with a new FFI operation, followed by a
public Ruby wrapper and no Paid runtime integration.

The prototype's isolated SDK/server harness must use a disposable Temporal
test-server namespace and must retain the original task-queue settings,
attempt limits, and deadlines. It is complete only when it executes all of the
following against the prototype API:

| Case | Required observation |
| --- | --- |
| idle worker | acknowledgement resolves with zero owners; final shutdown succeeds |
| unused poll reservation | acknowledgement waits until the outstanding poll is cancelled or safely settled, without spending an activity attempt |
| task-return race | a task returned at the fence becomes a tracked owner with its original attempt/deadline |
| eager path | an enabled eager activity is either tracked or safely settled before acknowledgement |
| active max-attempts=1 | quiesce and abort/resume preserve the sole owner's attempt and deadline |
| abort/resume | resume reopens admission without cancelling an owner or minting a retry |
| replacement and legacy first adoption | the replacement only stops after acknowledgement; an incapable legacy worker defers |

The current repository's focused updater tests are evidence only for the
protective legacy guard. They are not this SDK/server harness. The harness is
blocked on the Core/Ruby operation above; this block records the exact missing
interface rather than treating a source audit or an unexecutable sketch as a
passing lifecycle experiment.

## Local prototype feasibility record

The local proposal was checked against a fresh source checkout of Ruby SDK
1.11.0 (`61db6dd4b75e3b15731e58f26934b33c17663237`) and its recorded
`sdk-core` submodule (`c675c32469af707e1c979a7b808c70b4a0608b82`). The
implementation path is concrete: add the generation state and settlement
accounting in `crates/sdk-core/src/worker/mod.rs`, wire all activity/workflow
poll and eager sources through it, expose an asynchronous operation in
`temporalio/ext/src/worker.rs`, and add the public Ruby future API in
`temporalio/lib/temporalio/worker.rb`. The existing terminal
`Worker::initiate_shutdown` cannot be adapted because it cancels the terminal
token and unregisters eager work before it can support resume.

The local checkout was recreated with `git clone --branch v1.11.0 --depth 1
--recurse-submodules`; `HEAD` and the checked-out submodule resolved to the
revisions above. A disposable Rust 1.88.0 toolchain was then installed outside
the Paid repository, using `RUSTUP_HOME=/workspace/.paid-temporal-rustup` and
`CARGO_HOME=/workspace/.paid-temporal-cargo`. It could not execute even
`cargo --version`: the installed `cargo` proxy failed before Cargo started
with `OrbStack ERROR: Dynamic loader not found: /lib64/ld-linux-x86-64.so.2`.
The host reported `aarch64`; reinstalling with the
`aarch64-unknown-linux-gnu` default-host option produced the same proxy-loader
failure. Consequently `cargo test -p temporal-sdk-core --lib worker
--no-default-features` was not run, and no Core/Ruby prototype patch or
SDK/server harness result is claimed.

The checkout and toolchain were disposable research material and are not a
retained artifact or a Paid dependency. Issue #5358 owns provision of a
compatible isolated Rust runner. Once it supplies a verified runner, the
prototype owner must freshly clone the exact Ruby/Core revisions above there,
record the image and toolchain evidence, and run the baseline command before
preparing or claiming a Core/Ruby patch or lifecycle harness. No further local
toolchain installation or operating SDK pin change is part of this decision.
