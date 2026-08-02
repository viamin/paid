---
parent: PAID
prefix: CHAT-CONTAINER-PROVISIONING
---

# Low-Level Design: Chat Container Provisioning

> Companion to the high-level design (`docs/high-level-design.md`) and
> [RDR-037](../../rdrs/RDR-037-containerized-multi-repo-chat.md). This segment
> covers the background provisioning path that transitions a container-backed
> `ChatSession` from `pending` to `ready` without blocking the user's first
> message.

## Purpose

RDR-037 requires that a chat session accept the user's first message
immediately, provisioning the container in parallel with the initial inline
exchange. `ChatSessions::Create` is the only creation entry point; for
eager-enabled accounts it persists a session with
`container_capability: "pending"` but needs background work to advance that
state. This segment defines the background job that closes that gap and the
tenant-level toggle that governs whether it runs.

## Provisioning path

`ChatSessions::Create` enqueues `ChatSessions::ProvisionContainerJob` **after**
the create transaction commits. Enqueuing inside the transaction would race
the GoodJob worker: the job could pick up the ID before the row is visible and
silently no-op via `RecordNotFound`.

The job:

1. Guards against re-running by returning early unless the session is still in
   `container_pending?` or `container_provisioning?`; if a lifecycle event
   already moved the session to `ready`, `failed`, or `stopped`, the job is a
   no-op.
2. Calls `Containers::ProvisionForChat`, which owns the transition to
   `provisioning` to `ready`/`failed`, volume seeding, and cleanup on error.
3. Broadcasts `capability_changed` on the existing `chat_session:<id>` stream
   so the chat controller can update the capability badge without a page
   reload and without disturbing conversation history.

Errors from `Containers::ProvisionForChat::ProvisionError` and
`Docker::Error::DockerError` are contained: the provisioner has already
transitioned the session to `failed` and cleaned up any volumes it created, so
the job broadcasts the failure and logs a structured error rather than
re-raising and looping on a permanent failure. Timeouts and unexpected
`StandardError` failures still reload and broadcast the failed capability, then
re-raise so the normal job failure and notification path records the incident.
`ActiveRecord::RecordNotFound` is discarded; a deleted session cannot be
provisioned.

Per-session concurrency (`total_limit: 1`, `enqueue_limit: 1`) prevents
duplicate provisioning if `Create` runs twice for the same session ID.

## Tenant toggle

`TenantSetting#chat_eager_provisioning` (default `true`) is the opt-out for
operators with constrained container capacity. When disabled, the job is
never enqueued at create time; container-requesting sessions start
inline-only (`container_capability: "none"`) and only transition when a
container-only tool call triggers the lazy path.
Inline-only sessions (`container_capability: "none"`) are unaffected
regardless of the flag.

## Trust and scope

- The job runs on Paid's own infrastructure, not in a container. It operates
  only on data owned by the session's account.
- `ProvisionForChat` is the sole caller of Docker; this job never touches the
  daemon directly.
- Broadcasts carry only capability state (`container_capability`,
  `container_ready_at`): no secrets, no logs, no message content.
