# EARS Specs: Chat Session Reopen

> Testable claims for the RDR-037 workspace reopen flow and capability
> indicator. Status markers: `[x]` implemented, `[ ]` active gap, `[D]`
> deferred.

## Reopen flow

- [x] **CHAT-SESSION-REOPEN-001** - When a stopped container-backed chat
  session is reopened, the system SHALL reactivate the session, transition the
  workspace capability to `pending`, and enqueue background provisioning rather
  than blocking the request on container startup.
  *Tests:* `spec/services/chat_sessions/reopen_spec.rb`,
  `spec/system/chat_workspace_reopen_spec.rb`.
  *Code:* `ChatSessions::Reopen`,
  `ChatSessions::ProvisionContainerJob`.

- [x] **CHAT-SESSION-REOPEN-002** - When reopened provisioning succeeds, the
  system SHALL replay every saved `clone_manifest` entry into the new
  container so the workspace contents survive container reaping.
  *Tests:* `spec/services/chat_sessions/reopen_spec.rb`,
  `spec/system/chat_workspace_reopen_spec.rb`.
  *Code:* `ChatSessions::RestoreCloneManifest`,
  `ChatSessions::ProvisionContainerJob`.

- [x] **CHAT-SESSION-REOPEN-003** - When one or more manifest clones fail
  during reopen, the system SHALL mark only those manifest entries stale and
  SHALL persist a system message naming the failed repo(s) without dropping the
  rest of the workspace.
  *Tests:* `spec/services/chat_sessions/reopen_spec.rb`,
  `spec/system/chat_workspace_reopen_spec.rb`.
  *Code:* `ChatSessions::RestoreCloneManifest`.

- [x] **CHAT-SESSION-REOPEN-004** - Reopening an already-active workspace
  session SHALL be idempotent and SHALL NOT enqueue another provision job.
  *Tests:* `spec/services/chat_sessions/reopen_spec.rb`.
  *Code:* `ChatSessions::Reopen`.

## Capability indicator

- [x] **CHAT-SESSION-REOPEN-005** - Capability changes and clone-manifest
  updates SHALL broadcast the current workspace state over the chat session's
  ActionCable stream so the header indicator updates without a full reload.
  *Tests:* `spec/channels/chat_channel_spec.rb`,
  `spec/jobs/chat_sessions/provision_container_job_spec.rb`.
  *Code:* `ChatSessions::BroadcastCapabilityState`,
  `ChatSessions::CapabilitySnapshot`,
  `ChatSessions::HandleCapabilityTransition`.

- [x] **CHAT-SESSION-REOPEN-006** - Ready workspaces SHALL expose a
  "Clone another project" affordance that updates the workspace indicator with
  the newly cloned repo and its recorded token identity.
  *Tests:* `spec/system/chat_workspace_reopen_spec.rb`.
  *Code:* `ChatSessionsController#clone_project`,
  `app/views/chat_sessions/_capability_panel.html.erb`.
