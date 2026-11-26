---
node: temporal-orchestration
---

# Decision: Close reservations before acknowledging worker quiescence

## Contract and supported scope

Paid must replace poll and agent workers without cancelling an owned task or
spending an assigned task's original attempt behind an application fence.
The implementation uses the released Ruby SDK's custom workflow and remote
activity slot suppliers. It does not call private bridge methods or invent a
worker lifecycle API. A request to drain is distinct from acknowledgement.

The supported worker registers Paid's workflow classes, whose activity calls
use the remote `BaseWorkflow#run_activity` boundary. The fixed local-activity
supplier and all existing slot counts remain unchanged. This protocol does
not claim to fence arbitrary applications using local activities, Nexus, or
additional worker registrations. Such a configuration requires its own
ownership protocol before it can advertise this capability. This constraint
covers Paid's actual registered workflow scope, not a general SDK guarantee.

A capability is not accepted from a source audit or a file-lock test alone.
TEMPORAL-ORCHESTRATION-021 remains an open implementation claim until the real
supported SDK/server matrix below passes with truthful cleanup evidence.

## Worker protocol

`Paid::WorkerAdmission` provides a custom supplier for workflow slots and a
custom supplier for remote activity slots. Both use one stable per-process
admission-lock inode. A permit owns its shared lock from reservation until
SDK release, including an unused long-poll permit or eager permit.

A separate persistent drain request closes *future* reservation admission.
A blocking reservation checks the request before claiming capacity and again
after obtaining a nonblocking shared lock. If either check is closed or
unknown, it returns capacity and waits cancellably without issuing a permit.
The eager `try_reserve_slot` path performs only one nonblocking attempt and
returns nil when admission is closed. The public SDK can then schedule that
activity through its ordinary server path; eager execution is not disabled by
a namespace flag or new queue.

A request racing the final check cannot invalidate an issued permit: that
permit already owns a shared lock, so the controller cannot acknowledge its
exclusive fence until SDK release. An arriving task may finish as that
tracked owner before acknowledgement. No callback reacquires an admission
lock after assignment. `mark_slot_used` and `release_slot` do no waiting,
network access, readiness-file publication, or task-input logging.

Each supported worker publishes a capability version, admission scope,
random process-boot identity, canonical workspace identity, and the existing
boot revision in its readiness record. Activity-body counts remain
observations and never authorize a stop. Unknown or corrupt request metadata
closes reservations; missing or mismatched capability metadata cannot
produce a successful acknowledgement.

## Controller and updater boundary

`bin/lib/worker_admission.py` uses only the Python standard library so the
standalone updater does not depend on a bootable Rails application. It owns
a stable controller lock, request generation and per-role exclusive locks.
The updater consumer in `bin/dev-update` supplies the expected workspace,
role identities, target revision, and its existing finite drain budget. The
default `both` worker mode has two SDK workers in one process: their distinct
slot capacities share one boot identity and admission inode. The controller
coalesces that physical path while acknowledging both logical roles; it must
not attempt to acquire the same exclusive inode twice.

1. Validate every affected role before changing any admission state. Bind the
   readiness records to the expected workspace and supervisor-owned process
   identities; reject unsupported legacy workers and ambiguous records.
2. Serialize controllers and publish one owned generation for **all** roles
   before waiting for any exclusive lock. Duplicate paths are coalesced.
3. Retain exclusive locks in stable order while other roles settle. Recheck
   the same boot identities before acknowledging the complete role set.
   Outstanding unused reservations and active tasks must have released their
   shared ownership. A request alone, a zero body count or a partial role set
   is not acknowledgement.
4. Keep the acknowledged generation and locks alive through the existing
   stop/start and trusted target-revision verification. Controller descriptors
   are not inherited by restarted services. Gate every supported target launch
   path before acknowledgement, including a transition between one both-mode
   process and split role processes. New metadata paths do not remove the old
   generation's gates. Closing a parent shell's own
   descriptors alone is insufficient protection against inheritance.
5. Resume only the owned generation after successful target verification and
   typed proof that every original PID/start-time instance has exited. A fresh
   target marker does not prove the old worker stopped; unknown process
   visibility defers reopening. Abort before any stop may reopen only the
   unchanged workers before any stop checkpoint. Once a quit may be in flight,
   unchanged PIDs do not authorize abort. Repeated resume is
   idempotent. Persist verified target boots and resume intent before unlinking
   requests. Recovery after interrupted opening recloses missing owned gates,
   waits for any admitted target owners, then completes without another stop.
   No request may remove another controller's generation.

Normal timeout before acknowledgement removes only the caller's requests,
releases its locks and defers adoption without stopping a worker. An unknown
parent outcome after acknowledgement leaves a persistent closed generation
and a bounded diagnostic containing its exact recovery command. A recovery
invocation must acquire the controller lock, validate supported role identity
and reacquire all exclusive locks before continuing the existing restart.
It must classify unchanged, known mixed old/target, explicitly stopped, and
fully verified target cohorts. Stopped recovery requires typed absence of all
original PID/start-time instances and reacquires every persistent request lock;
it authorizes setup and target start, never reopening. Monotonic checkpoints
record stopping, stopped, setup and starting without granting new authority.
A completed generation verifies its recorded target boots and original-instance
absence without republishing requests or restarting services. A known mixed cohort remains fenced for completion of replacement;
only a fully verified target cohort can reopen, with the original instances
proved gone. Unknown boots or process visibility defer with the persistent
generation intact. It must not silently resume a mixed or unverifiable worker set. Ordinary
recovery does not renew task retries, deadlines, runner allowances or grants.

## Legacy first adoption

An unsupported worker cannot be made safe by inspecting an activity count.
Automatic adoption therefore refuses it before publishing a request or
stopping a process. Missing readiness also remains unknown unless the
supervisor positively establishes that no Temporal worker can be stopped.

The initial rollout is a separately authorized maintenance procedure, not an
automatic legacy drain. The current `GitHubPollWorkflow` continues polling and
continuing-as-new after external producers stop. Project pause is not a
workflow termination condition. `ProjectWorkflowManager.stop_polling` requests
asynchronous cancellation and immediately changes local bookkeeping; its
return or a cancelled database field is not a quiescence acknowledgement.
Its restart path can terminate a workflow and is not an owner-preserving
bootstrap operation.

A supported maintenance acceptance case must establish exclusive control of
the complete producer cohort and retain all finite business owners until they
finish under their original budgets. A genuine operator may explicitly request
normal cancellation of an **idle** continuous control workflow. Bind that
request to its exact workflow run. Record and verify the first-execution
identity through read-only metadata, then cancel through a public SDK handle
that carries the exact `run_id` and omits `first_execution_run_id`.
[Temporal 1.29.7 clears the requested run ID when the first-execution field is
supplied](https://github.com/temporalio/temporal/blob/v1.29.7/service/history/api/requestcancelworkflow/api.go#L29-L35),
so sending both fields can target a continued successor instead of the recorded
run. Never retarget after continue-as-new or treat a successful cancellation
RPC as proof that the recorded run was cancelled. Await the actual server terminal
result with following runs disabled, and inspect the history delta. Any owned
activity cancellation, timeout, unexpected business dispatch, a new continued
run, an unexcluded client or an unknown RPC outcome invalidates the bootstrap
proof. One empty pending-activity or task-backlog snapshot is insufficient.
The updater must not initiate that cancellation or treat an operator intent
record as evidence that work actually settled.

Only an actually closed producer cohort with verified terminal executions
permits ordinary public shutdown of legacy workers under their unchanged
grace. Verify termination of the original process identities. Start only the
new worker roles from the accepted revision while producer admission remains
held, verify their trusted boot and admission capabilities, and then explicitly
resume the producers through normal interfaces. Preserve the cancelled control
workflow's history; a new poll run is an explicit resume action, not an erased
failure or renewed code-run allowance. Do not use workflow termination, force
kill, fabricated readiness, namespace flags, new queues or larger concurrency.

Real continuous-poll, active-owner, arrival/continue-as-new race and interrupted
maintenance tests must qualify this path. Until those tests establish the
closed cohort and preserved owners, the legacy rollout remains **unverified**
and TEMPORAL-ORCHESTRATION-021 cannot be marked complete. Steady-state slot
coordination alone is insufficient.

## Required verification

### Retained environment and prototype evidence

The earlier Core proposal used Ruby source
`61db6dd4b75e3b15731e58f26934b33c17663237` and its Core gitlink
`c675c32469af707e1c979a7b808c70b4a0608b82`. With Rust 1.95.0 and
protoc 34.0, locked fetch and
`cargo check --locked --offline --package temporalio-sdk-core` completed
successfully from that Ruby workspace without changing its lockfile. This
retains the native decision's corrected baseline evidence. It is a compiler
check, not a worker-unit, new Core API, or lifecycle-harness pass. A separate
worker-unit attempt ended with ENOSPC before executing cases; its capacity
failure remains recorded under #5269. The historical loader failure's cause
was not reproduced and is not treated as established architecture evidence.

The accepted #5358 environment capability does not require a Core prototype
before the public SDK 1.9 protocol can be exercised. The current application
SDK pin remains unchanged. Public custom-supplier unit tests now have genuine
baseline and corrected results, but the full SDK/server and legacy cases below
remain mandatory. Neither an earlier compiler check nor those unit tests
proves task-safe adoption.

### SDK/server acceptance

Use the installed supported Ruby SDK and Temporal server with Paid's actual
codec, `BaseActivity` and verbatim tuner factory. Preserve original activity
heartbeat, start-to-close, workflow deadline, maximum attempts, shutdown grace,
queues, poll counts and slot counts. Retain all earlier failed histories.

- Ordinary and prefenced finite-attempt workflows remain positive controls.
- Truly idle SDK pollers acknowledge within the unchanged default drain
  budget; continued reservation renewal must not starve the writer.
- A permit issued before the request either remains safely queued or finishes
  as an owner before physical exclusive acknowledgement. Exercise task arrival
  during settling as well as arrival after acknowledgement.
- No body starts while the exclusive fence is held, and no owner is abandoned
  at stop. Record request, permit, task/body, acknowledgement and release times
  separately, with the corresponding actual server events and attempts.
- Both roles, workflow and remote activity polls, sticky polling and enabled
  eager admission are covered. Callback immediacy is observed directly.
- Abort, repeated drain, cancellation, replacement, unknown metadata,
  generation ownership, interrupted-controller recovery and descriptor
  inheritance are tested. Unrelated processes and admission paths remain live.
- Legacy refusal and the controlled empty-workload bootstrap are exercised;
  a new-worker-only demonstration does not prove rollout safety.

Private matrix results, code delivery, effective worker adoption and a genuine
recorder-owned operating closeout remain distinct acceptance boundaries.

## Decisions and alternatives

| Choice | Disposition | Reason |
| --- | --- | --- |
| Fence inside activity bodies | Rejected | Task assignment and heartbeat ownership already happened. |
| Release unused ownership and reacquire in `mark_slot_used` | Rejected | Assignment can occur under an exclusive fence, and notification callbacks must not block. |
| Reservation-to-release ownership without closing new reservations | Rejected | New readers can prevent an idle worker from acknowledging within its drain budget. |
| Two-stage request plus reservation-to-release ownership | Selected for implementation and real verification | Existing public callbacks can keep every external permit owned while stopping renewal; acknowledgement is exclusive ownership, not a counter. |
| Ordinary shutdown as the admission fence | Rejected | Its grace can cancel owners and it cannot provide reversible admission. |
| Private Core/bridge methods or a hypothetical released API | Rejected | They are outside the supported installed interface. |
| General local-activity or Nexus worker support | Outside this Paid configuration | Their reservation and descendant-ownership protocols require independent evidence; this protocol does not advertise them. |
