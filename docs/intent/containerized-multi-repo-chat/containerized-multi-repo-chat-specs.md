# EARS Specs: Containerized Multi-Repo Chat

> Testable claims for the planned multi-repo chat capability model. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r MULTI-REPO-CHAT-001`).

- [x] **MULTI-REPO-CHAT-001** — When a chat session is created with background
  workspace support enabled, the system SHALL accept the first user message
  immediately and provision container capability asynchronously instead of
  blocking session creation on container setup.
  *Tests:* `spec/services/chat_sessions/create_spec.rb`,
  `spec/jobs/chat_sessions/provision_container_job_spec.rb`.
  *Code:* `ChatSessions::Create#enqueue_background_provisioning`,
  `ChatSessions::ProvisionContainerJob`, `db/migrate/20260729193401_add_container_capability_to_chat_sessions.rb`.

- [x] **MULTI-REPO-CHAT-002** — When container capability becomes ready, the
  system SHALL update the session's available tool surface without losing
  conversation history so the same chat can move from inline reasoning to
  workspace-backed actions.
  *Tests:* `spec/services/chat_sessions/handle_capability_transition_spec.rb`.
  *Code:* `ChatSessions::HandleCapabilityTransition#publish_tools_list_changed`,
  `Tools::Registry.mcp_definition_for` (capability-gated tool availability).

- [x] **MULTI-REPO-CHAT-003** — When a user clones additional authorized
  repositories into a chat workspace, the system SHALL persist a clone manifest
  that can be replayed when the session is reopened after container teardown.
  *Tests:* `spec/mcp/tools/clone_project_spec.rb`,
  `spec/services/chat_sessions/reopen_spec.rb`.
  *Code:* `Tools::CloneProject`, `ChatSession#append_clone_manifest_entry`,
  `ChatSessions::RestoreCloneManifest`, `ChatSessions::Reopen`.

- [x] **MULTI-REPO-CHAT-004** — When a chat session holds multiple repositories,
  mutable workspace tools SHALL recompute authorization per project instead of
  trusting stale clone-time access metadata.
  *Tests:* `spec/mcp/tools/write_repo_file_workspace_mutation_tools_spec.rb`,
  `spec/mcp/tools/run_shell_spec.rb`,
  `spec/services/containers/provision_for_chat_workspace_mutation_tools_integration_spec.rb`.
  *Code:* `Tools::ContainerRepoSupport#repo_context_for!` (per-project Pundit
  re-authorization), `Tools::RunShell.all_manifest_projects_mutable?`.

- [D] **MULTI-REPO-CHAT-005** — Accounts MAY later opt into lazy provisioning as
  a budget-saving fallback, but the primary product contract for this segment
  is eager background provisioning with in-session capability upgrade. (The lazy
  `chat_eager_provisioning = false` path is implemented; the spec stays deferred
  as the optional, non-headline contract.)

- [ ] **MULTI-REPO-CHAT-006** — When a chat session holds workspace changes in
  cloned repos, the system SHALL offer a `propose_pull_request` tool that creates
  a branch, pushes via the resolved GitHub identity, and opens a PR whose body
  carries `Depends on owner/repo#N` lines for cross-repo coordination, requiring
  `project.run_agent?` on the target repo and recomputing authorization per
  project. *Open gap:* `Tools::ProposePullRequest` is not implemented and
  `propose_pull_request` is not registered. This is the motivating cross-repo
  coordination capability for this segment and the single remaining RDR-037
  requirement; tracked by the RDR-037 closeout follow-up.
