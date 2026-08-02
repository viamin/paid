# EARS Specs: Chat Container Provisioning

> Testable claims for background provisioning of container-backed chat
> sessions (RDR-037). Status markers:
> `[x]` implemented, `[ ]` active gap, `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r CHAT-CONTAINER-PROVISIONING-001`).

## Background provisioning

- [x] **CHAT-CONTAINER-PROVISIONING-001** - When a chat session is created
  with a container-requesting capability (`container_capability: "pending"`)
  and the account has eager provisioning enabled, the system SHALL enqueue
  `ChatSessions::ProvisionContainerJob` after the create transaction commits
  so the first inline message is never blocked on container readiness.
  *Tests:* `spec/services/chat_sessions/create_spec.rb`
  ("enqueues background provisioning for a pending session",
  "does not block on provisioning").
  *Code:* `ChatSessions::Create#enqueue_background_provisioning`.

- [x] **CHAT-CONTAINER-PROVISIONING-002** - The provisioning job SHALL be a
  no-op unless the session is still in `container_pending?` or
  `container_provisioning?`, so late or duplicate runs do not re-provision a
  session that already reached `ready`, `failed`, or `stopped`.
  *Tests:* `spec/jobs/chat_sessions/provision_container_job_spec.rb`
  ("when the session is #{capability}: does not provision or broadcast").
  *Code:* `ChatSessions::ProvisionContainerJob#perform`.

- [x] **CHAT-CONTAINER-PROVISIONING-003** - On success, the job SHALL
  broadcast `capability_changed` on `chat_session:<id>` with the resulting
  `container_capability` and `container_ready_at` so the chat UI updates
  without a page reload and without losing conversation history.
  *Tests:* `spec/jobs/chat_sessions/provision_container_job_spec.rb`
  ("broadcasts the capability change to the chat stream").
  *Code:* `ChatSessions::ProvisionContainerJob#broadcast_capability`.

- [x] **CHAT-CONTAINER-PROVISIONING-004** - When provisioning raises
  `Containers::ProvisionForChat::ProvisionError` or
  `Docker::Error::DockerError`, the job SHALL contain the error, broadcast
  the `failed` capability, and log a structured error rather than re-raising
  and looping on a permanent failure. `ActiveRecord::RecordNotFound` for a
  deleted session SHALL be discarded.
  *Tests:* `spec/jobs/chat_sessions/provision_container_job_spec.rb`
  ("broadcasts the failed capability without re-raising",
  "contains a raw Docker error without re-raising",
  "when the session no longer exists: is discarded without raising").
  *Code:* `ChatSessions::ProvisionContainerJob#perform` (rescue block),
  `discard_on ActiveRecord::RecordNotFound`.

## Tenant opt-out

- [x] **CHAT-CONTAINER-PROVISIONING-005** - When
  `TenantSetting#chat_eager_provisioning` is `false`, the system SHALL NOT
  enqueue background provisioning at session create time; the session
  remains `pending` and only transitions via the lazy path. Inline-only
  sessions (`container_capability: "none"`) SHALL NOT enqueue provisioning
  regardless of the flag.
  *Tests:* `spec/services/chat_sessions/create_spec.rb`
  ("skips background provisioning when eager provisioning is disabled",
  "does not enqueue provisioning for an inline-only session",
  "enqueues background provisioning when eager provisioning is enabled"),
  `spec/requests/tenant_configurations_spec.rb` (chat_eager_provisioning toggle).
  *Code:* `ChatSessions::Create#eager_provisioning_enabled?`,
  `TenantSetting#chat_eager_provisioning`.

- [x] **CHAT-CONTAINER-PROVISIONING-006** - Background provisioning SHALL use
  GoodJob concurrency controls with `total_limit: 1`, `enqueue_limit: 1`, and
  a key scoped to the chat session ID so duplicate jobs cannot provision the
  same workspace concurrently.
  *Tests:* `spec/jobs/chat_sessions/provision_container_job_spec.rb`
  (".good_job_concurrency_config").
  *Code:* `ChatSessions::ProvisionContainerJob.good_job_concurrency_config`,
  `ChatSessions::ProvisionContainerJob.concurrency_key_for`.
