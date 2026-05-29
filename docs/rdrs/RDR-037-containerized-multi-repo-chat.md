# RDR-037: Containerized Multi-Repo Chat Sessions

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-05-29
- **Status**: Draft
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: #2349 (chat-auth invariant), #2350 (admin tools), #2351 (operator tools), #2352 (source-code tools), #2353 (dangerous_mode audit), #2354 (this RDR's tracking issue)
- **Related RDRs**: [RDR-028](RDR-028-interactive-chat.md) (interactive chat — this RDR supersedes its workspace-mode design), [RDR-004](RDR-004-container-isolation.md) (container isolation), [RDR-005](RDR-005-git-worktree-management.md) (worktree management), [RDR-006](RDR-006-secrets-proxy.md) (secrets proxy)

## Problem Statement

RDR-028 shipped interactive chat with two distinct modes — `api` (inline LLM call, no filesystem) and `workspace` (single-project container, provisioned synchronously on session create). This binary is now the limiting factor for three real use cases:

1. **Dependent updates across repos.** Adding a feature that requires coordinated changes in `agent-harness` and `paid` (with PRs that reference each other via the dependency parser described in `CLAUDE.md`) requires two separate chat sessions today. The user has to manage the cross-repo reasoning in their head, and nothing in the session understands that the two PRs are linked.

2. **Time-to-first-token vs. capability trade-off.** A user who opens a `workspace`-mode session waits ~30s for container provisioning before sending the first message — even if the first message is "what's in this issue?" and never needs the filesystem. A user who opens `api` mode and *then* wants to read a file has to start a new session.

3. **Scope-locked at session creation.** The decision of "which project's repo is this session about" must be made before the first message. A conversation that organically grows to need a second repo cannot acquire one — even if the user has access to both projects in Paid.

The system also has no concept of "container is being prepared in the background." Provisioning is synchronous, so the UX cost of having a workspace is paid at every session start.

### Requirements

- Single chat session can clone and reason across multiple repos
- First user message accepted immediately — no synchronous container wait
- Container provisioned in the background, in parallel with the first inline exchange
- Seamless capability upgrade when the container is ready, with no loss of conversation history
- Projects can be cloned into a running container on demand (within the user's Pundit-authorized set)
- Per-session resource caps that scale with cloned repo count
- Container lifecycle independent of session lifecycle (sessions outlive their containers; reopening recreates the container and re-clones from a saved manifest)

## Context

### What RDR-028 gave us

- `ChatSession` model with `mode: api|workspace` and `status: active|idle|closed` ([app/models/chat_session.rb:25-26](../../app/models/chat_session.rb#L25-L26))
- `Containers::ProvisionForChat` ([app/services/containers/provision_for_chat.rb](../../app/services/containers/provision_for_chat.rb)) — synchronous provisioner with a workspace volume seeded from a single project's git repo
- Per-session state volume mounted at `~/.claude`, `~/.codex`, etc. for CLI session resume
- MCP server endpoint at `/api/mcp/call` with 12 read/run tools and session-token auth
- Idle reaper job that transitions sessions to `idle` and destroys the container

### What's missing

- No background provisioning path — `ProvisionForChat` is called synchronously from `ChatSessions::Create`
- Workspace volume is seeded with **one** project's clone; no concept of additional clones during a session
- `mode` is set at create and never changes — there is no transition state for "API now, container later"
- MCP tool list is static per session; tools that require a container (none exist today; future write/shell tools will) cannot appear/disappear based on container readiness
- No saved manifest of "which repos were in this session" — closing destroys both container and the knowledge of what was cloned

### Constraints inherited from RDR-004

- Containers are unprivileged, read-only root fs, no `CAP_SYS_ADMIN`, tmpfs for `/tmp`
- Network egress restricted (Paid MCP server + LLM APIs only via secrets proxy)
- Per-container resource caps enforced at the Docker layer

## Research Findings

### Background-provision UX patterns

Three usable shapes:

1. **Fire-and-forget on create.** Job enqueued at `ChatSessions::Create`; UI shows a "container ready" indicator when it lands. Simple, but if the first tool call needing the container fires before ready, it has to wait or fail.
2. **Lazy on first need.** Container is provisioned only when a container-only tool is invoked. Less wasted work for chats that never need it, but worst-case latency for the user who actually wants the container ("I have to wait *now*").
3. **Eager-on-create with reservation.** Container provisioned in background on create, *and* the session tracks which tool calls are waiting for it so chat can stream "preparing your workspace…" inline and resume when ready.

We adopt **(3)** as the default with **(2)** as a configurable fallback for accounts with tight container budgets. (3) gives the best UX for users who treat chat as a development tool; (2) is right for users who treat chat as a Q&A assistant.

### Multi-repo layout in a single container

Flat: one directory per cloned repo under `/workspace/<project-slug>/`. The container is already account-scoped (one container per session, sessions belong to a single account), so no further namespacing is needed. Easy to enumerate, no collisions within a session.

### Conversation continuity across mode transitions

The LLM does not need to be re-introduced when the container becomes ready — it needs a *tool-list update*. MCP supports `notifications/tools/list_changed` for exactly this case. When the container goes from `provisioning` → `ready`, Paid emits the notification; the next assistant turn sees the expanded tool surface (clone, file write, shell). Conversation history is unaffected.

### GitHub token identity per clone

Each `clone_project(project)` call hits the same token-identity decision as the `read_repo_file` tool (issue #2352): try the user's linked GitHub token first, fall back to the project's stored token, and record which one was used in the tool result. Container only sees the clone token as a single-use env var during the clone exec (same pattern as today's `ProvisionForChat` at [provision_for_chat.rb:247-259](../../app/services/containers/provision_for_chat.rb#L247-L259)).

## Proposed Solution

### Approach

Collapse `mode: api|workspace` into a single session shape that *has* a container capability which can be `none`, `pending`, `provisioning`, `ready`, or `failed`. The session begins responsive immediately (inline LLM call) and gains containerized capabilities as the container comes online. Multi-repo is the natural consequence: once a container exists, any project the user can `show?` can be cloned into it.

### Technical Design

```
┌────────────────────────────────────────────────────────────────────────┐
│                MULTI-REPO CHAT SESSION (RDR-037)                        │
│                                                                         │
│  ┌──────────────┐    ActionCable/SSE     ┌──────────────────────────┐  │
│  │  BROWSER UI  │ ◄────────────────────► │     PAID RAILS APP       │  │
│  └──────────────┘                         │                           │  │
│                                           │  ChatSessions::Create     │  │
│                                           │   ├─► inline LLM ready    │  │
│                                           │   └─► enqueue Provision   │  │
│                                           │                            │  │
│                                           │  ChatSessions::Provision  │  │
│                                           │  ContainerJob (GoodJob)   │  │
│                                           │   └─► ProvisionForChat    │  │
│                                           │       (no project seed)   │  │
│                                           │                            │  │
│                                           │  ChatSessions::SendMessage│  │
│                                           │   ├─► inline transport    │  │
│                                           │   └─► routes container-   │  │
│                                           │       only tools to       │  │
│                                           │       container exec      │  │
│                                           │                            │  │
│                                           │  PaidMcpServer            │  │
│                                           │   ├─► account/read tools  │  │
│                                           │   ├─► repo-read tools     │  │
│                                           │   ├─► container-only:     │  │
│                                           │   │     clone_project     │  │
│                                           │   │     write_repo_file   │  │
│                                           │   │     run_shell         │  │
│                                           │   │     apply_patch       │  │
│                                           │   │     propose_pr        │  │
│                                           │   └─► tools/list_changed  │  │
│                                           │       on capability flip  │  │
│                                           └──────────┬─────────────────┘  │
│                                                      │                    │
│                                                      ▼                    │
│                                         ┌─────────────────────────┐      │
│                                         │   DOCKER CONTAINER       │      │
│                                         │                          │      │
│                                         │   /workspace/            │      │
│                                         │     ├── repo-1/  (clone) │      │
│                                         │     ├── repo-2/  (clone) │      │
│                                         │     └── repo-3/  (clone) │      │
│                                         │                          │      │
│                                         │   state volume:          │      │
│                                         │     ~/.claude, etc.      │      │
│                                         │                          │      │
│                                         │   MCP client → Paid      │      │
│                                         └─────────────────────────┘      │
└────────────────────────────────────────────────────────────────────────┘
```

### Data Model Changes

```ruby
# chat_sessions (modify)
# - Drop:        mode (string)
# - Add:         container_capability  string  # none|pending|provisioning|ready|failed|stopped
# - Add:         container_requested_at datetime
# - Add:         container_ready_at     datetime
# - Add:         clone_manifest         jsonb   # [{project_id, cloned_at, path, token_identity}]
# - Keep:        container_id, workspace_volume, idle_timeout_at
```

`mode` is removed in favor of `container_capability`. Existing rows migrate as:

- `mode = "api"` → `container_capability = "none"`
- `mode = "workspace"` → `container_capability = "ready"` if container_id present, `"stopped"` otherwise

`clone_manifest` records every successful clone so the session can be reopened later (container destroyed, then recreated and re-cloned from the manifest).

### Session Lifecycle

```
1. ChatSessions::Create(account:, projects: [...])
   ├── persist session, container_capability = "none"
   ├── if account allows background containers AND user did not opt out:
   │   ├── set container_capability = "pending"
   │   └── enqueue ChatSessions::ProvisionContainerJob
   └── return session (UI shows chat ready immediately)

2. ChatSessions::ProvisionContainerJob (GoodJob, low priority)
   ├── transition "pending" → "provisioning"
   ├── ProvisionForChat.call(chat_session: session, seed_project: nil)
   ├── if any projects[] specified at create:
   │   └── for each: clone into /workspace/<slug>/, update clone_manifest
   ├── transition to "ready"
   └── broadcast tools/list_changed via MCP + UI capability indicator

3. ChatSessions::SendMessage (user message arrives)
   ├── inline LLM call as today
   ├── if assistant invokes a container-only tool:
   │   ├── if container_capability == "ready":
   │   │   └── exec in container, stream result
   │   ├── if container_capability in ["pending","provisioning"]:
   │   │   ├── stream user-visible "preparing workspace…" message
   │   │   ├── await container readiness (bounded, e.g. 60s)
   │   │   └── on ready: exec; on timeout: tool call returns
   │   │       structured "container_unavailable" so the LLM can retry
   │   │       or fall back
   │   └── if container_capability == "failed":
   │       └── tool returns error; system prompt updates to note degraded
   │           capability

4. Assistant invokes clone_project(project)
   ├── Pundit: project.show? for current user
   ├── resolve clone token (user GH token, fallback project GH token)
   ├── docker exec git clone into /workspace/<project-slug>/
   ├── append to clone_manifest
   └── result includes path and which token identity was used

5. Idle / close
   ├── ChatSessions::IdleReaper destroys container, preserves clone_manifest,
   │   transitions container_capability to "stopped"
   ├── On user reopen: re-provision container, replay clone_manifest
   └── On user close: destroy container + volumes, archive session
```

### Tool Surface by Capability

| Tool | Inline-only OK | Requires container |
|------|----------------|--------------------|
| `list_projects`, `get_project`, `get_project_issues`, `get_project_pull_requests`, `get_issue_details`, `get_pull_request_details`, `get_agent_run`, `list_agent_runs`, `cancel_agent_run`, `trigger_agent_run`, `search_code` | ✅ | — |
| `read_repo_file`, `list_repo_tree`, `grep_repo` (from #2352) | ✅ (via GitHub API) | ✅ (faster: read from local clone if cloned) |
| Admin/operator tools (from #2350, #2351) | ✅ | — |
| `clone_project` | — | ✅ |
| `write_repo_file`, `apply_patch` | — | ✅ |
| `run_shell` | — | ✅ |
| `git_diff`, `git_status`, `git_branch_create` | — | ✅ |
| `propose_pull_request(project, branch, title, body, depends_on?: [...])` | — | ✅ |

Container-only tools are filtered out of `tools/list` until `container_capability == "ready"`. The `tools/list_changed` MCP notification fires on every capability transition.

### Cross-Repo PR Coordination

`propose_pull_request` accepts a `depends_on: ["owner/repo#N", ...]` list and writes the dependency lines into the PR body using Paid's existing dependency-parser syntax (`Depends on owner/repo#N`, see `CLAUDE.md` "GitHub Issues" section). The user can ask chat to "ship these two changes together" and the dependency parser will hold the dependent PR's auto-merge until its upstream lands. No new dependency machinery is required.

### Resource Caps (Multi-Repo Adjusted)

```ruby
CHAT_DEFAULTS = {
  memory_bytes: 2 * 1024 * 1024 * 1024,  # 2GB base (unchanged from RDR-028)
  cpu_quota: 100_000,                    # 1 CPU
  pids_limit: 500,
  idle_timeout: 30.minutes,
  max_cloned_repos: 5,                   # NEW: cap clones per session
  max_workspace_disk_mb: 4096,           # NEW: enforced via tmpfs / quota
  clone_timeout_per_repo: 120            # NEW: per-clone wall-clock
}
```

`max_cloned_repos` is a soft default — accounts with multi-repo workflows can raise it via `TenantSettings`. The disk cap is enforced by the workspace volume size limit, not by quotas inside the container.

### Authorization

Every container-only tool inherits the framework chokepoint from issue #2349:

- `current_user` resolved and `TenantContext.with(user.account)` opened for the whole call
- `clone_project` Pundit-checks `project.show?` (same gate as the read tools)
- `propose_pull_request` Pundit-checks `project.run_agent?` (same gate as `trigger_agent_run`)
- `run_shell` is Pundit-checked against the session's *primary* project's `run_agent?` policy — shell access is treated as equivalent privilege to triggering an agent run, and accounts can disable it entirely via `TenantSettings.chat_shell_enabled`

The cloning token decision (user GH token first, project token fallback, identity surfaced in result) matches issue #2352 — same helper.

## Alternatives Considered

### Alternative 1: Per-message container spin-up

**Description**: No persistent container. Each tool call that needs a workspace spins up a short-lived container, performs the action, and tears down.

**Pros**: No idle resource cost; no lifecycle bugs; trivial cleanup.

**Cons**: ~10–30s overhead *per tool call*; cross-tool state (clones, in-progress edits, shell history) impossible without reseeding from scratch every time. Multi-repo workflows become unusable because each repo would have to be re-cloned per call.

**Rejected**: The multi-repo workflow that motivates this RDR is fundamentally stateful — the cost of statelessness is exactly what we are trying to remove.

### Alternative 2: Lazy provisioning only (no background path)

**Description**: Keep `api`-mode default. Provision a container only when a container-only tool is first invoked. Drop the background job.

**Pros**: Simpler implementation; no wasted containers for chats that never need one.

**Cons**: The user *who actually wants a container* pays the full 30s wait inline, which is exactly the UX failure RDR-028 has today. We lose the "responsive immediately, capable shortly" property that makes the new model worth building.

**Rejected as default**, **kept as opt-in**: accounts with tight container budgets can flip `chat_eager_provisioning = false` and get the lazy path.

### Alternative 3: One container per project, federated within a session

**Description**: Keep RDR-028's one-project-one-container model, but allow a session to be associated with multiple containers and route tool calls to the right one.

**Pros**: Each project's workspace is isolated; resource caps are per-project; clearer security boundary.

**Cons**: Cross-repo workflows — the exact motivating use case — become enormously complex (cross-container file movement, separate shell histories, two PRs that can't see each other's branches). The user is back to mental coordination, just at finer granularity.

**Rejected**: Defeats the purpose. The single-container/multi-clone model is what makes coordinated cross-repo changes feel like one workspace.

### Alternative 4: Replace chat with a devcontainer-in-IDE flow

**Description**: Stop building chat-driven workspaces. Send users to a VS Code devcontainer for multi-repo work.

**Pros**: Mature tooling; users already know it; no new infrastructure.

**Cons**: Loses the natural-language interface entirely, defeats the broader chat-as-alternate-UI vision, and forces users out of Paid for any non-trivial work.

**Rejected**: Wrong product direction. Chat is the differentiator.

## Trade-offs and Consequences

### Positive

- **Cross-repo workflows become first-class.** Dependent PRs across `agent-harness` + `paid` (and similar pairs) can be reasoned about and proposed within a single session.
- **No mode decision up front.** Users start typing immediately and gain capabilities as the container warms.
- **Conversation continuity across capability transitions.** The MCP `tools/list_changed` mechanism handles this cleanly without re-priming the LLM.
- **Session outlives container.** Reopening a closed session restores the workspace by replaying `clone_manifest`.
- **Sets up future tools cleanly.** `run_tests`, `bisect`, `evaluate_patch`, and other container-side tools fit the same capability-gated registration.

### Negative

- **More moving parts.** Background job + capability state machine + dynamic tool list + clone manifest is materially more state than the current binary mode.
- **Resource utilization rises.** Eager provisioning means containers exist for chats that never end up using them (mitigated by per-account opt-out and the idle reaper).
- **Container exec is now in the hot path of `SendMessage`.** Errors that today live in `ProvisionForChat` (Docker daemon hiccups, image pull failures) now surface during conversation. Need graceful degradation.
- **Migration cost.** Existing `mode`-shaped rows and any UI/API that reads `mode` must move to `container_capability`.

### Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Container failure mid-conversation surfaces as a broken chat | High | Capability transitions to `failed`; tool calls return structured `container_unavailable`; LLM can choose to fall back to API-only tools (e.g. `read_repo_file` via GitHub) |
| User clones 50 repos and exhausts container disk | Medium | `max_cloned_repos` cap + workspace volume size limit; `clone_project` rejects with a clear error |
| Multi-repo PR proposals fan out into many uncoordinated PRs | Medium | `propose_pull_request` requires explicit `depends_on` declarations for related PRs; a default warning if more than one repo has uncommitted changes at propose time |
| Background provisioning costs add up for users who never trigger container tools | Medium | Per-account `chat_eager_provisioning` flag; idle reaper destroys unused containers on the standard timeout |
| Reopening a session with stale `clone_manifest` (project deleted, repo renamed) | Low | Re-provision marks failed clones in the manifest and surfaces them to chat as a system message; user can decide to retry or skip |
| `run_shell` exposes too much surface | High | Default off via `TenantSettings.chat_shell_enabled`; when enabled, Pundit-gated on `run_agent?` for the primary project; container constraints from RDR-004 still apply |

## Implementation Plan

### Prerequisites

- [ ] Issue #2349 (auth invariant framework) landed — every new tool inherits the chokepoint
- [ ] Issue #2352 (source-code read tools) landed — provides the token-identity helper reused by `clone_project`

### Step-by-Step

#### Step 1: Data model + capability state machine

- Migration: add `container_capability`, `container_requested_at`, `container_ready_at`, `clone_manifest` to `chat_sessions`
- Migration: backfill from existing `mode` rows, then drop `mode`
- `ChatSession`: replace `mode` predicates with capability predicates (`container_ready?`, `container_pending?`, etc.)
- Update Logidze coverage (`chat_sessions` is not currently logidze-tracked per `CLAUDE.md`; do not add unless required for audit)

#### Step 2: Background provisioning

- New `ChatSessions::ProvisionContainerJob` (GoodJob, low priority, account-scoped concurrency)
- `ChatSessions::Create` enqueues the job when `chat_eager_provisioning` is true (default), skips when false
- `ProvisionForChat`: split current single-project seed out of the main path; default to provisioning an empty `/workspace/`
- On provision success: broadcast capability change + MCP `tools/list_changed`
- On provision failure: capability → `failed`; surface a system message in the session

#### Step 3: Capability-aware tool registry

- `Tools::Registry.tools_for(session, user)` filters by capability *and* by Pundit (today only Pundit)
- `PaidMcpServer.tools_list` consults the session and emits the correct list
- Implement `tools/list_changed` notification dispatch over the existing MCP transport

#### Step 4: Container-only tools (initial set)

- `Tools::CloneProject` — clones a project, updates `clone_manifest`, surfaces token identity
- `Tools::WriteRepoFile` — writes a file in a cloned repo (path validated against `clone_manifest`)
- `Tools::RunShell` — Pundit-gated, off by default, capped wall-clock per call
- `Tools::ApplyPatch` — applies a unified diff against a cloned repo
- `Tools::ProposePullRequest` — creates a branch, pushes via the resolved GH identity, opens a PR with `depends_on` lines

#### Step 5: SendMessage integration

- When the LLM emits a container-only tool call and capability is `pending`/`provisioning`: stream "preparing workspace…" turn, await readiness with a bounded timeout, then exec
- When capability is `failed`: tool call returns structured error so the LLM can choose to fall back
- Idle timeout extends on container-using tool calls (separate counter from inline chat)

#### Step 6: Reopen flow

- `ChatSessions::Reopen` (new service) — re-provisions container, iterates `clone_manifest`, re-clones each project, surfaces any failures as a system message at the start of the conversation
- UI surface: "reopen with workspace" button on `idle`/`stopped` sessions

#### Step 7: UI capability indicator

- Chat header shows: capability state, cloned repos with paths, "clone another project" affordance
- Capability changes pushed over the existing `ChatChannel`

### Files to Create / Modify

**New**:

- `db/migrate/YYYYMMDD_replace_chat_session_mode_with_capability.rb`
- `app/jobs/chat_sessions/provision_container_job.rb`
- `app/services/chat_sessions/reopen.rb`
- `app/services/chat_sessions/handle_capability_transition.rb`
- `app/mcp/tools/clone_project.rb`
- `app/mcp/tools/write_repo_file.rb`
- `app/mcp/tools/run_shell.rb`
- `app/mcp/tools/apply_patch.rb`
- `app/mcp/tools/propose_pull_request.rb`

**Modify**:

- `app/models/chat_session.rb` — capability predicates, drop `mode`
- `app/services/chat_sessions/create.rb` — enqueue background provisioning
- `app/services/chat_sessions/send_message.rb` — route container-only tool calls, capability waiting
- `app/services/containers/provision_for_chat.rb` — multi-repo layout; remove single-project seeding from default path
- `app/mcp/tools/registry.rb` — capability-aware filtering, `tools/list_changed` dispatch
- `app/mcp/paid_mcp_server.rb` — dynamic tool list per session
- `app/channels/chat_channel.rb` — capability state broadcasts
- `app/views/chat_sessions/_config_bar.html.erb` (or equivalent) — capability indicator
- `config/routes.rb` — reopen route if needed

## Validation

### Testing Approach

- **Unit**: capability state machine transitions; `clone_manifest` round-trip; tool filtering by capability
- **Integration**: full lifecycle — create → first inline message → background provision completes → tool call routes to container → close → reopen replays manifest
- **System**: browser chat that clones two repos, reads files from both, proposes two dependent PRs
- **Security**: parity spec from #2349 covers every new container-only tool; specific assertions that `clone_project` cannot clone a project the user lacks `show?` for, and that `run_shell` is denied when disabled at tenant level

### Test Scenarios

| Scenario | Expected Result |
|----------|-----------------|
| Create session, send first message before container ready | Response streams from inline transport, no wait for container |
| LLM invokes `clone_project` during provisioning | Chat streams "preparing workspace…", tool exec runs once ready |
| LLM invokes `clone_project` for a project the user cannot `show?` | Tool returns authorization error; nothing cloned; no leakage of project existence |
| Clone two repos, ask "what depends on Foo across both?" | `grep_repo` runs on each cloned repo; results aggregated |
| `propose_pull_request` with `depends_on: ["owner/repo#42"]` | PR body includes `Depends on owner/repo#42`; existing dependency parser blocks auto-merge until #42 lands |
| Idle reaper destroys container with 3 cloned repos | Session moves to `stopped`; `clone_manifest` preserved |
| Reopen the above session | New container provisioned, all 3 repos re-cloned per manifest, session resumes |
| Project deleted between close and reopen | Reopen surfaces a system message naming the failed clone; rest of session usable |
| Account with `chat_eager_provisioning = false` | No background job; container provisioned lazily on first container-only tool call |
| `run_shell` invoked when `TenantSettings.chat_shell_enabled = false` | Tool not present in `tools/list`; if invoked anyway, returns authorization error |

### Performance Validation

- Inline first-token latency: unchanged from API mode (≤2s)
- Background provisioning latency: ≤45s p95 (slower than RDR-028's synchronous path is acceptable because user is not waiting)
- Clone latency: ≤30s p95 for repos under 100MB
- `tools/list_changed` propagation: ≤500ms from capability transition to client receipt
- Reopen latency: scales linearly with number of cloned repos; show progress per-repo in UI

### Security Validation

- All new container-only tools route through the `BaseTool#dispatch` chokepoint from #2349
- `clone_project` cannot bypass Pundit `project.show?`
- Container token-identity logging shows which GH token was used per clone, surfaced to user and recorded in audit
- `run_shell` honors `TenantSettings.chat_shell_enabled` and per-project `run_agent?`
- Cross-repo PR proposals do not leak token credentials into PR bodies or branch names
- Container network egress restrictions from RDR-004 unchanged

## References

### Requirements & Standards

- `CLAUDE.md`: all LLM calls through `agent_harness`; GitHub issue dependency syntax (`Depends on owner/repo#N`); `TenantContext` rules
- RDR-004: container isolation guarantees this RDR inherits
- RDR-006: secrets proxy is the only egress path for LLM calls from inside the container
- RDR-028: original chat architecture; this RDR supersedes its workspace-mode design

### Issues

- #2349 — chat-auth invariant framework (prerequisite)
- #2350 — admin tool surface
- #2351 — operator tool surface
- #2352 — source-code read tools (provides token-identity helper)
- #2353 — `dangerous_mode` audit
- #2354 — tracking issue for this RDR

### Dependencies

- `agent_harness` chat transport (already shipped per RDR-028)
- GoodJob (already in use for background jobs)
- Docker API + `Containers.backend` (already in use)
- MCP `tools/list_changed` notification (already in MCP spec; implementation may need a small extension in the MCP server)
