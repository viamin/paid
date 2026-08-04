# RDR-037 Audit Report — 2026-08-04

## Summary

RDR-037 is no longer accurately described as "tracked but not implemented". As of
Tuesday, August 4, 2026, the repository ships the core containerized multi-repo
chat capability model: capability state, background provisioning, multi-repo
clone manifests, the full set of container-only workspace mutation tools, shell
execution, and the reopen/restore lifecycle.

The closeout issue for this audit is
[#3165](https://github.com/viamin/paid/issues/3165). The reconciliation against
the RDR's open requirements and the closed tracking chain
[#2354](https://github.com/viamin/paid/issues/2354) found that **five of the six**
core requirements RDR-037 lists as open have actually shipped. One remains open:
the `propose_pull_request` cross-repo PR-proposal tool.

A second goal of this audit was to confirm that the **API-mode / source-code read
tools** (issue [#2352](https://github.com/viamin/paid/issues/2352)) are not being
mistaken for workspace mutation support. They are not: they are GitHub-API-backed
read tools that never enter the container and do not mutate the workspace. The
true workspace mutation support is a distinct, container-only tool surface that
all declare `requires_container? = true`.

## GitHub State

- Tracking issue [#2354](https://github.com/viamin/paid/issues/2354) is closed.
- Child issues [#2349](https://github.com/viamin/paid/issues/2349),
  [#2350](https://github.com/viamin/paid/issues/2350),
  [#2351](https://github.com/viamin/paid/issues/2351),
  [#2352](https://github.com/viamin/paid/issues/2352), and
  [#2353](https://github.com/viamin/paid/issues/2353) are closed.
- Closeout / gap-reconciliation issue
  [#3165](https://github.com/viamin/paid/issues/3165) is open.

## Reconciliation: RDR-037's "open" requirements vs. the code

| Requirement (as RDR-037 lists it) | Status | Evidence |
|---|---|---|
| Capability state (`none`/`pending`/`provisioning`/`ready`/`failed`/`stopped`) | **Shipped** | `chat_sessions.container_capability` column + `ChatSession` predicates + `ChatSessions::HandleCapabilityTransition` |
| Background provisioning | **Shipped** | `ChatSessions::ProvisionContainerJob` (GoodJob, low-priority, account-scoped concurrency), enqueued by `ChatSessions::Create`; lazy provision via `Tools::Registry`/`ChatSessions::ToolDispatch` |
| Multi-repo clone manifests | **Shipped** | `chat_sessions.clone_manifest` + `ChatSession::CloneManifestEntry`; `Tools::CloneProject`; `ChatSessions::RestoreCloneManifest`/`Reopen` |
| Mutation tools (write/patch/git) | **Shipped** | `Tools::WriteRepoFile`, `Tools::ApplyPatch`, `Tools::GitDiff`, `Tools::GitStatus`, `Tools::GitBranchCreate` |
| Shell execution | **Shipped** | `Tools::RunShell` (tenant-gated, audited, path-validated) |
| PR-proposal tooling | **Not shipped** | `Tools::ProposePullRequest` does not exist; no `propose_pull_request` tool registered |

## What Shipped

### Capability state machine

- Migration `db/migrate/20260729193401_add_container_capability_to_chat_sessions.rb`
  adds `container_capability`, `container_requested_at`, `container_ready_at`, and
  `clone_manifest`, backfills from the legacy `mode` column, and is the source of
  truth for the RDR's data-model changes. `mode` is now in `self.ignored_columns`.
- `app/models/chat_session.rb` carries the capability predicates
  (`container_ready?`, `container_pending?`, `container_provisioning?`,
  `container_failed?`, `container_stopped?`, `inline_only?`) and the
  `request_container_provision!` transition with a `with_lock` guard.
- `app/services/chat_sessions/handle_capability_transition.rb` broadcasts the
  capability change to the chat stream and publishes the MCP
  `tools/list_changed` notification via `publish_tools_list_changed`.

### Background provisioning

- `app/services/chat_sessions/create.rb` `enqueue_background_provisioning`
  enqueues `ProvisionContainerJob` when the session requests a container and eager
  provisioning is enabled, and forces inline-only start when an account defers —
  exactly the eager-on-create-with-reservation vs. lazy-on-need split from the
  RDR's research findings.
- `app/jobs/chat_sessions/provision_container_job.rb` provisions on the
  low-priority queue with `total_limit: 1` per account, is a no-op unless the
  session is still `pending`/`provisioning`, contains Docker failures, and
  re-enqueues the next pending session.
- `app/services/chat_sessions/provision_workspace.rb` centralizes the
  provision + manifest-restore contract so the eager job, the agent-loop lazy
  path, and the MCP `tools/call` lazy path all restore the full clone set.

### Multi-repo clone manifests

- `Tools::CloneProject` (`app/mcp/tools/clone_project.rb`) clones an authorized
  project into `/workspace/<project-slug>/`, enforces a per-account
  `chat_max_cloned_repos` cap, resolves the clone token via the same
  identity helper as the read tools, and appends a `clone_manifest` entry with
  token identity. It re-clones stale entries left by a failed reopen.
- `ChatSession#append_clone_manifest_entry`/`#remove_clone_manifest_entry`/
  `#replace_clone_manifest_entry` manage the persisted manifest.
- `ChatSessions::RestoreCloneManifest` + `ChatSessions::Reopen` replay the
  manifest on reopen so a reaped workspace is rebuilt from its saved clones;
  restore failures reclaim resources, surface a system message, and return the
  session to the retryable `stopped` state.

### Mutation tools

- `Tools::WriteRepoFile`, `Tools::ApplyPatch`, `Tools::GitDiff`,
  `Tools::GitStatus`, and `Tools::GitBranchCreate` all operate against cloned
  repos via `Tools::ContainerRepoSupport`, which resolves the manifest entry for
  the target path, re-authorizes with Pundit (`project.show?` for reads,
  `project.run_agent?` for mutations), and validates paths against the workspace
  root before any container exec.
- Coverage: `spec/mcp/tools/{write_repo_file,apply_patch,git_diff,git_status,git_branch_create}_spec.rb`
  plus the cross-cutting `write_repo_file_workspace_mutation_tools_spec.rb` and
  `spec/services/containers/provision_for_chat_workspace_mutation_tools_integration_spec.rb`.

### Shell execution

- `Tools::RunShell` (`app/mcp/tools/run_shell.rb`) executes shell commands inside
  the container. Per RDR-037 it is only advertised when the **entire** clone
  manifest revalidates as mutable for the current user (`all_manifest_projects_mutable?`),
  is gated by `TenantSetting#chat_shell_enabled`, validates the working directory
  against a manifest path, caps wall-clock time, truncates output, and records an
  audit event. Coverage: `spec/mcp/tools/run_shell_spec.rb`.

### Capability-aware tool registry and SendMessage integration

- `Tools::Registry` (`app/mcp/tools/registry.rb`) filters by capability:
  `requires_container?` tools stay discoverable but advertise
  `temporaryUnavailable` until `container_ready?`, and `dispatch_mcp` triggers
  lazy provisioning or returns a retryable `container_unavailable` result.
- `ChatSessions::ToolDispatch#dispatch_container_tool` implements the RDR's
  "preparing workspace…" turn: it triggers lazy provisioning when `none`/`stopped`,
  streams the announcement, awaits readiness with a bounded 60s timeout when
  `pending`/`provisioning`, and returns a structured `container_unavailable`
  result on failure/timeout.

## API-mode / source-code tools are NOT workspace mutation support

A stated goal of this audit was to confirm the two are not conflated. They are
distinct:

- **API-mode source-code read tools** (`Tools::ReadRepoFile`, `Tools::ListRepoTree`,
  `Tools::GrepRepo`, from [#2352](https://github.com/viamin/paid/issues/2352)) are
  read-only, resolve a GitHub-API client via `RepoReadClientResolver`, and never
  declare `requires_container?`. They do not mutate any workspace.
- **Workspace mutation support** is the container-only surface above
  (`clone_project`, `write_repo_file`, `apply_patch`, `run_shell`, `git_*`),
  every one of which declares `requires_container? = true` and executes inside
  the session container.

The reason the prior "tracked but not implemented" framing was wrong is precisely
that the mutation surface shipped alongside the capability model; the read tools
are a separate, already-closed concern and must not be counted as — or confused
with — containerized multi-repo workspace mutation.

## What Is Still Missing

### PR-proposal tooling (`propose_pull_request`) — the single open gap

The RDR's headline use case — "ship these two changes together" across dependent
repos — depends on a `propose_pull_request(project, branch, title, body,
depends_on?: [...])` tool that creates a branch, pushes via the resolved GitHub
identity, and opens a PR whose body carries `Depends on owner/repo#N` lines so the
existing dependency parser coordinates auto-merge.

- `Tools::ProposePullRequest` (`app/mcp/tools/propose_pull_request.rb`) does not
  exist and `propose_pull_request` is not in `Tools::Registry::TOOL_CLASSES`.
- The only references to `propose_pull_request` in the repository are inside the
  RDR document itself.
- The workspace can now clone multiple repos, mutate files, create branches, and
  run shell — but it cannot surface those changes as coordinated cross-repo PRs.

This is the motivating cross-repo coordination capability and the only one of the
six core requirements that did not ship. It should be represented by one focused
follow-up issue.

## Conclusion

RDR-037 should now be treated as **Partially Implemented**:

- Five of the six core requirements shipped with test coverage: capability state,
  background provisioning, multi-repo clone manifests, mutation tools, and shell
  execution, plus the capability-aware registry, `tools/list_changed`
  notification, SendMessage integration, and reopen/restore lifecycle.
- The remaining requirement — PR-proposal tooling (`propose_pull_request`) — is
  genuinely unimplemented and is the cross-repo coordination use case that
  motivates the RDR. It is tracked as the single open follow-up.

The repo docs should stop saying "tracked but not implemented" and should instead
distinguish the shipped capability model and mutation surface from the open
PR-proposal work.
