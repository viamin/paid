# RDR-028: Interactive Chat for Agent-Driven Development

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-04-23
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: TBD
- **Related RDRs**: [RDR-007](RDR-007-agent-cli-abstraction.md) (agent-harness), [RDR-004](RDR-004-container-isolation.md) (containers), [RDR-006](RDR-006-secrets-proxy.md) (secrets proxy), [RDR-025](RDR-025-runner-quota-tracking.md) (quota tracking)

## Implementation Status

Implemented for API-mode interactive chat: sessions, messages, UI/API routes, streaming, tool calls, MCP tools, token tracking, and write-tool confirmation are present. The workspace/container chat mode described here is superseded by RDR-037, which tracks containerized multi-repo chat and workspace mutation tools.

## Problem Statement

Paid orchestrates AI agents to build software through a batch-oriented workflow: label an issue, queue an agent run, wait for the PR. This workflow is powerful but cannot handle four increasingly important use cases:

1. **Design larger features through back-and-forth with an AI agent** — Current agent runs are single-shot. A user cannot iteratively refine a design, discuss trade-offs, or pivot mid-conversation. Complex features need multi-turn reasoning.

2. **Interactively debug issues** — When Paid or one of its managed projects has a bug, the user must manually inspect logs, read code, formulate a prompt, and run an agent. An interactive session where the agent can inspect files, run commands, and respond to follow-up questions would be far more efficient.

3. **Handle complicated cross-project requests** — Some work spans multiple repos and doesn't fit into a single project issue. Users need an ad-hoc workspace where they can reference multiple projects, ask questions across codebases, and get coordinated responses.

4. **Operate Paid itself via a chat interface** — Paid's UI requires navigating multiple pages to manage projects, providers, and runs. An AI assistant that understands Paid's data model and can trigger operations (create project, start run, view logs) through natural language would be more efficient than browsing and clicking.

### Requirements

- Multi-turn conversation with streaming responses
- Workspace access (read/write files, run commands) for debugging and code modification
- Cross-project context (reference multiple projects in one session)
- Tool-calling capability so the agent can interact with Paid's features
- Provider-agnostic: works with GitHub Models (Copilot), Claude, Gemini, and other agent-harness providers
- Account-level scoping with optional project association
- Token usage tracking and cost limits

## Context

### Background

Paid's current execution model is optimized for batch processing:

1. User labels a GitHub issue (or triggers a custom run)
2. Paid queues an agent run
3. A Temporal workflow provisions a Docker container
4. The agent CLI runs inside the container with a single prompt
5. Output is captured, PR is created, container is destroyed

This model is excellent for autonomous coding tasks but breaks down for interactive work. Each message would require a full container lifecycle, and there is no mechanism for the user to respond to the agent's questions mid-run.

### Current Architecture Limitations

| Limitation | Current State | What Chat Needs |
|------------|---------------|-----------------|
| No session model | Agent runs are stateless fire-and-forget | Persistent conversation with message history |
| No message model | `AgentRunLog` captures stdout/stderr, not conversational turns | Structured user/assistant/tool messages |
| No real-time streaming to browser | Turbo Streams replace HTML partials on status changes | Incremental text streaming during response generation |
| Container-per-run | Container created and destroyed for each agent run | Persistent or reusable containers for session duration |
| CLI-centric providers | Agent CLIs run `-p "prompt"` one-shot commands | API-based chat with multi-turn conversation |
| No tool calling | Agent CLIs have their own tool use (file edit, shell) | Paid-exposed tools via MCP for account/project operations |
| Single-project scope | Agent runs belong to one project | Cross-project sessions with multiple project contexts |

### Technical Environment

- **Agent-harness 0.10.0**: CLI-centric with one HTTP transport (Anthropic TextTransport). No conversation management, no chat API abstraction, no streaming HTTP support.
- **GitHub Models API**: OpenAI-compatible REST endpoint at `models.inference.ai.azure.com`. Supports chat completions with streaming (SSE), tool/function calling, and multi-turn conversations. Accessible with a GitHub token.
- **Container infrastructure**: Docker containers with hardened images, tmpfs mounts, git worktrees. Container pool for reuse. Idle timeout management exists for agent runs.
- **Real-time UI**: Turbo Streams (via ActionCable) for HTML replacement. No custom ActionCable channels. No SSE endpoints.
- **Database**: PostgreSQL with JSONB, UUID external IDs, row-level security for multi-tenancy.

## Research Findings

### Investigation Process

1. Analyzed agent-harness 0.10.0 provider adapter interface, execution pipeline, and transport layer
2. Evaluated GitHub Models API, Copilot SDK, and GitHub Copilot CLI capabilities
3. Reviewed Paid's container provisioning, Temporal workflow, and queue system
4. Assessed existing real-time UI patterns (Turbo Streams) and chat-like UI gaps
5. Surveyed MCP (Model Context Protocol) support in agent-harness

### Key Discoveries

**GitHub Models API is the simplest path for Copilot integration:**

```ruby
# Standard OpenAI-compatible format
POST https://models.inference.ai.azure.com/chat/completions
Authorization: Bearer <github_token>
Content-Type: application/json

{
  "model": "gpt-4o",
  "messages": [
    {"role": "system", "content": "You are..."},
    {"role": "user", "content": "Hello"}
  ],
  "stream": true,
  "tools": [{"type": "function", "function": {...}}]
}
```

This endpoint works with a standard GitHub token (no Copilot subscription required for GPT-4o; Copilot subscription enables premium models like Claude Sonnet, Gemini Pro).

**Per-message CLI execution with session resume avoids persistent process management:**

Instead of keeping a CLI process alive (fragile, complex I/O handling), each user message triggers a new CLI invocation with `--resume <session_id>`. The CLI maintains its own conversation state on disk. A persistent Docker volume mounts the CLI's state directory.

```
Message 1: docker exec <container> claude -p "Hello" --output-format json
           → Response includes session_id: "abc-123"
           → Session state saved to ~/.claude/ on persistent volume

Message 2: docker exec <container> claude -p "Follow up" --resume abc-123
           → CLI loads prior context, continues conversation
```

**MCP is the right tool interface for Paid operations:**

agent-harness already has MCP server abstractions (`McpServer` class, `build_mcp_flags`). Adding HTTP transport support for MCP servers lets the agent CLI in a container connect to Paid's MCP server over the network. This is provider-agnostic — any agent CLI that supports MCP can use Paid's tools.

**Provider chat support matrix:**

| Provider | API Chat | CLI Session Resume | Container Executable |
|----------|----------|-------------------|---------------------|
| GitHub Models | OpenAI-compatible | N/A | No |
| Claude | Anthropic Messages API | `--resume` | Yes |
| Gemini | Gemini API | TBD | Yes |
| Codex | OpenAI API | TBD | Yes |

## Proposed Solution

### Approach

Implement a two-mode chat architecture:

1. **API mode** (lightweight): Direct HTTP calls to LLM APIs. No container needed. Conversation history managed by Paid. Good for planning, operating Paid, general Q&A.

2. **Workspace mode** (container-backed): Agent CLI runs inside a Docker container with workspace access. Conversation continuity via CLI session resume or API calls from within the container. Good for debugging, code modification, running commands.

Both modes support MCP tools for Paid operations. The user selects the mode when creating a session; API mode is default for speed, workspace mode for deep work.

### Technical Design

```
┌──────────────────────────────────────────────────────────────────────┐
│                    INTERACTIVE CHAT ARCHITECTURE                      │
│                                                                       │
│  ┌──────────────┐     SSE/ActionCable     ┌─────────────────────────┐│
│  │  BROWSER UI  │ ◄──────────────────────► │    PAID RAILS APP      ││
│  │              │                           │                         ││
│  │ Chat view    │                           │ ChatSessionsController ││
│  │ Message list │                           │ ChatMessagesController ││
│  │ Input bar    │                           │ ChatChannel (Cable)    ││
│  └──────────────┘                           │                         ││
│                                             │ ┌─────────────────────┐ ││
│                                             │ │ Service Layer       │ ││
│                                             │ │ ChatSessions::Create│ ││
│                                             │ │ ChatSessions::Send  │ ││
│                                             │ │ ChatSessions::Close │ ││
│                                             │ └─────────────────────┘ ││
│                                             │                         ││
│                                             │ ┌─────────────────────┐ ││
│                                             │ │ Paid MCP Server     │ ││
│                                             │ │ list_projects       │ ││
│                                             │ │ trigger_agent_run   │ ││
│                                             │ │ search_code         │ ││
│                                             │ └─────────────────────┘ ││
│                                             └──────────┬──────────────┘│
│                                                        │               │
│                       ┌────────────────────────────────┤               │
│                       │ API mode                       │ Workspace mode│
│                       ▼                                ▼               │
│           ┌──────────────────┐             ┌──────────────────────┐   │
│           │ agent-harness    │             │  DOCKER CONTAINER    │   │
│           │ ChatTransport    │             │                      │   │
│           │                  │             │  Agent CLI process   │   │
│           │ OpenAI-Compat    │             │  (claude --resume)   │   │
│           │ Anthropic Chat   │             │                      │   │
│           │                  │             │  Workspace volume    │   │
│           └────────┬─────────┘             │  (git worktree)      │   │
│                    │                        │                      │   │
│                    ▼                        │  ┌────────────────┐  │   │
│           ┌──────────────────┐             │  │ MCP Client     │  │   │
│           │ LLM APIs         │             │  │ → Paid MCP     │  │   │
│           │ GitHub Models    │             │  └────────────────┘  │   │
│           │ Anthropic        │             └──────────────────────┘   │
│           │ OpenAI           │                                        │
│           └──────────────────┘                                        │
└──────────────────────────────────────────────────────────────────────┘
```

### Data Model

```
chat_sessions
  belongs_to :account
  belongs_to :project (optional)
  belongs_to :provider (optional)
  belongs_to :created_by, class: User
  has_many :messages, class: ChatMessage
  has_many :chat_session_projects
  has_many :projects, through: :chat_session_projects

  status: active | idle | closed | archived
  mode: api | workspace
  model: string (e.g., "gpt-4o")
  system_prompt: text
  container_id: string (nullable, workspace mode)
  workspace_volume: string (nullable)
  idle_timeout_at: datetime

chat_messages
  belongs_to :chat_session
  role: system | user | assistant | tool
  content: text
  tool_call_id: string (nullable)
  tool_name: string (nullable)
  tool_arguments: jsonb (nullable)
  tool_result: jsonb (nullable)
  tokens_input: integer (nullable)
  tokens_output: integer (nullable)

chat_session_projects (join table, cross-project sessions)
  belongs_to :chat_session
  belongs_to :project
  context_type: primary | reference
```

### Conversation Flow

**API mode:**

```
1. User creates session → ChatSessions::Create
   - Select provider + model
   - Optional: associate project(s)
   - System prompt constructed from context

2. User sends message → ChatSessions::SendMessage
   - Persist user ChatMessage
   - Load full conversation from chat_messages
   - Call agent-harness send_chat_message(conversation:, tools:, stream: true)
   - Stream response chunks to browser via ActionCable
   - On complete: persist assistant ChatMessage(s), token counts
   - Reset idle_timeout_at

3. Agent calls MCP tool → PaidMcpServer
   - Tool call appears in streaming response
   - Paid executes tool via service layer
   - Tool result returned to agent
   - Tool call/result persisted as ChatMessage

4. User closes session → ChatSessions::Close
   - Archive messages
   - Compute final token/cost totals
```

**Workspace mode:**

```
1. User creates session → ChatSessions::Create(mode: workspace)
   - Provision Docker container with git worktree
   - Mount persistent volume for agent session state
   - Inject MCP server URL for Paid tools
   - Return container status

2. User sends message → ChatSessions::SendMessage
   - Persist user ChatMessage
   - docker exec <container> <cli> -p "<message>" --resume <session_id>
   - Stream stdout to browser via ActionCable
   - On complete: persist assistant ChatMessage
   - Reset container idle_timeout_at

3. User closes session → ChatSessions::Close
   - Destroy container and workspace volume
   - Archive messages
   - Compute final token/cost totals
```

### System Prompt Construction

The system prompt is built dynamically from multiple sources:

```ruby
module ChatSessions
  class BuildSystemPrompt
    def call(session:)
      sections = []
      sections << base_identity
      sections << paid_capabilities(session) if session.has_tools?
      sections << project_context(session) if session.project
      sections << cross_project_context(session) if session.projects.many?
      sections << workspace_context(session) if session.workspace_mode?
      sections.compact.join("\n\n")
    end
  end
end
```

### MCP Tool Definitions

Paid exposes these tools via an MCP server (HTTP transport):

| Category | Tool | Description |
|----------|------|-------------|
| Projects | `list_projects` | List user's accessible projects |
| Projects | `get_project` | Project details, repo, settings |
| Projects | `get_project_issues` | Issues with status filters |
| Projects | `get_project_pull_requests` | PRs with review status |
| Agent Runs | `trigger_agent_run` | Start run on an issue |
| Agent Runs | `get_agent_run` | Run details, status, output |
| Agent Runs | `list_agent_runs` | Recent runs with filters |
| Agent Runs | `cancel_agent_run` | Cancel in-flight run |
| Context | `search_code` | Semantic search across project |
| Context | `get_issue_details` | Full issue body + comments |
| Context | `get_pull_request_details` | Full PR + reviews |
| Context | `get_file_content` | Read file from project repo |
| Account | `list_providers` | Configured providers |
| Account | `get_settings` | Current user settings |
| Account | `update_settings` | Update settings (validated) |

### Real-Time Streaming

Two complementary channels:

1. **ActionCable `ChatChannel`**: Bidirectional channel for session state. Subscribed when user opens a chat session. Receives:
   - `message_start` — assistant message begins (with id, model)
   - `message_chunk` — streaming text delta
   - `message_tool_call` — tool call detected (name, args)
   - `message_tool_result` — tool execution result
   - `message_complete` — assistant message finished (tokens, cost)
   - `session_status` — idle warning, session closed, etc.

2. **SSE fallback**: `POST /chat/:id/messages` with `Accept: text/event-stream` returns SSE events with the same payload format. Useful for API consumers and simpler client implementations.

### Container Lifecycle for Workspace Mode

```ruby
module Containers
  class ProvisionForChat
    CHAT_DEFAULTS = {
      memory_bytes: 2 * 1024 * 1024 * 1024,  # 2GB (lower than agent runs)
      cpu_count: 1,
      idle_timeout: 30.minutes,
      wall_clock_timeout: 4.hours
    }.freeze

    def call(session:)
      container = provision(
        image: "paid-agent:latest",
        workspace: create_workspace_volume(session),
        tmpfs: session_tmpfs_mounts,
        env: chat_env(session),
        **CHAT_DEFAULTS
      )
      session.update!(container_id: container.id, idle_timeout_at: 30.minutes.from_now)
    end
  end
end
```

Container idle management:

- `ChatSessions::IdleReaper` job runs every 5 minutes
- Finds sessions where `idle_timeout_at < now` and `status == 'active'`
- Transitions to `idle` status (container destroyed but session archived)
- User can re-open (creates new container, loads conversation history)

### agent-harness Changes (Upstream)

All provider-specific knowledge and transport logic belongs in agent-harness per AGENTS.md. Required additions:

| Component | Description |
|-----------|-------------|
| `OpenAICompatibleTransport` | HTTP client for OpenAI-format chat completions API (covers GitHub Models, OpenAI, OpenRouter) |
| `Conversation` | Message history manager with token counting, truncation, and format conversion |
| Provider `supports_chat?` / `send_chat_message` | Chat capability flag and unified entry point on provider adapter |
| MCP HTTP transport | `McpServer` support for `http`/`sse` transports (server-side) |
| Streaming observer | `on_chat_chunk` callback for structured streaming deltas |

## Alternatives Considered

### Alternative 1: API-Only (No Container Support)

**Description**: Only use HTTP API calls for chat. No workspace access, no file system, no command execution.

**Pros**:

- Much simpler implementation (no container lifecycle management)
- Faster session creation (no Docker overhead)
- Lower resource consumption per session

**Cons**:

- Cannot debug issues that require inspecting files or running commands
- Cannot do code modification through chat
- Less useful for the "interactively debug" use case
- Requires separate path for workspace tasks

**Reason for rejection**: The user specifically wants container-backed workspace access for debugging and code modification. An API-only approach would leave the most valuable use case unsupported.

### Alternative 2: Persistent CLI Process with Stdin/Stdout

**Description**: Keep a single CLI process running inside the container. Send messages via stdin, read responses from stdout.

**Pros**:

- True interactive session (no `--resume` overhead)
- Lower latency between messages (no process startup)
- Natural fit for interactive CLI use

**Cons**:

- Fragile: process crashes kill the session
- Complex I/O handling (buffering, partial reads, encoding issues)
- No clean timeout/cleanup mechanism
- Debugging is difficult (process state is opaque)
- Not all provider CLIs support persistent stdin mode

**Reason for rejection**: Per-message execution with session resume is more robust and aligns with the existing container execution patterns in Paid. The overhead of CLI startup per message is acceptable for interactive chat (sub-second for most providers).

### Alternative 3: External Chat Platform (e.g., Slack, Discord Integration)

**Description**: Build chat into an existing messaging platform via bot integration instead of a native UI.

**Pros**:

- No chat UI to build
- Users already in Slack/Discord
- Notifications and threading built-in

**Cons**:

- No workspace access (can't show file contents, diffs inline)
- Limited formatting (code blocks, tool call displays)
- No streaming support (platform APIs are request/response)
- Security surface: Paid data flowing through third-party platform
- Different auth model (bot tokens vs user sessions)

**Reason for rejection**: The chat feature needs tight integration with Paid's data model, workspace visualization, and streaming responses. A native UI provides the best user experience and avoids third-party dependencies.

### Alternative 4: Third-Party Chat SDK (e.g., Stream Chat, Pusher Chatkit)

**Description**: Use a hosted chat SDK for the UI and real-time infrastructure.

**Pros**:

- Battle-tested chat UI components
- Built-in message persistence, typing indicators, read receipts
- Managed WebSocket infrastructure

**Cons**:

- Additional SaaS dependency and cost
- Less control over message format (tool calls, code blocks)
- Vendor lock-in for core feature
- Paid already has ActionCable infrastructure

**Reason for rejection**: Paid's chat has unique requirements (tool call display, streaming LLM output, MCP integration) that don't map well to generic chat SDKs. ActionCable + Turbo Streams provides sufficient real-time infrastructure.

## Trade-offs and Consequences

### Positive Consequences

- **Multi-turn reasoning**: Users can iteratively refine designs, debug issues, and explore solutions through conversation
- **Cross-project awareness**: Single session can reference multiple projects, enabling holistic planning
- **Self-service operations**: Users can manage Paid through natural language instead of navigating multiple pages
- **Provider flexibility**: Works with any provider that has chat transport support in agent-harness
- **Reusable infrastructure**: Chat sessions, MCP tools, and conversation management can be extended for future features (e.g., chat-driven CI/CD, collaborative debugging)

### Negative Consequences

- **Container cost**: Workspace-mode sessions consume Docker resources for their duration (mitigated by idle timeout)
- **Token consumption**: Interactive chat can consume significant tokens, especially with long conversations and tool calls (mitigated by cost tracking and limits)
- **Complexity**: Two execution modes (API vs workspace) add system complexity. Container lifecycle for chat is a new operational concern
- **Upstream dependency**: Paid chat depends on agent-harness additions (chat transport, conversation manager). Development must be coordinated

### Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Container resource exhaustion from too many active chat sessions | High | Per-account session limits, idle timeout, container pool cap |
| Token costs escalate unexpectedly | High | Per-session and per-account token budgets, real-time cost display |
| MCP tools expose destructive operations | High | Read-only by default, write operations require confirmation step, Pundit authorization per tool |
| Upstream agent-harness changes delayed | Medium | API mode can launch first using direct HTTP calls; workspace mode waits for upstream |
| Long conversations exceed context window | Medium | Conversation truncation with summarization (in agent-harness Conversation class) |
| Container idle timeout kills active session | Low | Heartbeat on each message, configurable timeout, graceful transition to 'idle' (recoverable) |

## Implementation Plan

### Prerequisites

- [ ] agent-harness 0.11.0+ released with OpenAI-compatible transport and conversation manager
- [ ] GitHub Models API access verified (GitHub token with `copilot` scope)
- [ ] Paid test infrastructure supports chat API testing

### Step-by-Step Implementation

#### Sprint 1: agent-harness Upstream (4 issues)

1. **AH-1: OpenAI-Compatible Chat Transport**
   - Add `lib/agent_harness/openai_compatible_transport.rb`
   - Implement chat completions with SSE streaming
   - Tool/function calling support
   - Error mapping and retry logic

2. **AH-2: Conversation Manager**
   - Add `lib/agent_harness/conversation.rb`
   - Message history with token tracking
   - Context window management with truncation
   - Format conversion for different transports

3. **AH-3: Provider Chat Capability**
   - Add `supports_chat?` and `send_chat_message` to adapter
   - Implement for GithubCopilot (via GitHub Models) and Anthropic
   - Update `ProviderRuntime` for chat options

4. **AH-5: Streaming Response Observer**
   - Add `on_chat_chunk` callback for structured streaming
   - Integrate with transport streaming
   - Compatible with existing observer pattern

#### Sprint 2: Paid Core (3 issues)

1. **PAID-1: Chat Database Schema**
   - Migrations for `chat_sessions`, `chat_messages`, `chat_session_projects`
   - Models with associations, validations, scopes
   - Indexes and foreign key constraints

2. **PAID-2: Chat Session Service Layer**
   - `ChatSessions::Create`, `SendMessage`, `Close`
   - Conversation history management
   - System prompt construction
   - Integration with agent-harness chat API

3. **AH-4: MCP HTTP Transport** (parallel, in agent-harness)
   - HTTP/SSE transport support in `McpServer`
   - Provider-side flag updates

#### Sprint 3: Paid API and UI (2 issues)

1. **PAID-3: Chat API Endpoints**
   - REST endpoints for session CRUD
   - Message endpoint with SSE streaming
   - ActionCable `ChatChannel`
   - Rate limiting and authorization

2. **PAID-6: Chat UI**
   - Session list view
   - Chat view with message thread
   - Streaming text display
   - Message input with provider/model selector
   - Stimulus controllers for chat interaction

#### Sprint 4: Advanced Features (3 issues)

1. **PAID-4: Chat Container Manager**
    - `Containers::ProvisionForChat` service
    - Persistent volume management
    - Idle timeout and cleanup
    - Container health monitoring

2. **PAID-5: Paid MCP Server**
    - `PaidMcpServer` with tool definitions
    - HTTP endpoint for MCP connections
    - Authentication via session token
    - Pundit authorization per tool

3. **PAID-7: Chat System Prompt & Context + PAID-8: Cost Tracking**
    - Dynamic system prompt builder
    - Project knowledge injection
    - Token usage tracking per session/message
    - Cost limits and budget display

### Files to Create/Modify

**agent-harness (new files)**:

- `lib/agent_harness/openai_compatible_transport.rb`
- `lib/agent_harness/conversation.rb`
- `lib/agent_harness/providers/adapter.rb` (add chat methods)
- `lib/agent_harness/providers/base.rb` (default chat implementation)
- `lib/agent_harness/providers/github_copilot.rb` (add chat support)
- `lib/agent_harness/providers/anthropic.rb` (extend for chat)

**Paid (new files)**:

- `app/models/chat_session.rb`
- `app/models/chat_message.rb`
- `app/models/chat_session_project.rb`
- `app/services/chat_sessions/create.rb`
- `app/services/chat_sessions/send_message.rb`
- `app/services/chat_sessions/close.rb`
- `app/services/chat_sessions/build_system_prompt.rb`
- `app/services/chat_sessions/idle_reaper.rb`
- `app/services/containers/provision_for_chat.rb`
- `app/mcp/paid_mcp_server.rb`
- `app/mcp/tools/*.rb` (individual tool definitions)
- `app/controllers/chat_sessions_controller.rb`
- `app/controllers/chat_messages_controller.rb`
- `app/channels/chat_channel.rb`
- `app/javascript/controllers/chat_controller.js`
- `app/javascript/controllers/chat_input_controller.js`
- `app/javascript/controllers/chat_stream_controller.js`
- `app/views/chat_sessions/*.html.erb`
- `db/migrate/YYYYMMDD_create_chat_sessions.rb`
- `db/migrate/YYYYMMDD_create_chat_messages.rb`
- `db/migrate/YYYYMMDD_create_chat_session_projects.rb`

**Paid (modify)**:

- `config/routes.rb` (add chat routes)
- `app/models/account.rb` (add has_many :chat_sessions)
- `app/models/project.rb` (add has_many :chat_sessions)
- `app/policies/chat_session_policy.rb` (new)
- `app/policies/chat_message_policy.rb` (new)

### Dependencies

```
AH-1 ─┬─► AH-2 ──► AH-3
       ├─► AH-5
       └─► PAID-2 ──► PAID-3 ──► PAID-6

AH-4 ──────────────► PAID-5

PAID-1 ────────────► PAID-2
                    PAID-4
                    PAID-7
                    PAID-8
```

## Validation

### Testing Approach

- **Unit tests**: Chat session service layer, message formatting, system prompt construction, MCP tool definitions
- **Integration tests**: Full chat flow (create session → send message → receive response → close)
- **System tests**: Browser-based chat UI interaction with streaming
- **Container tests**: Workspace mode container lifecycle (provision, exec, idle timeout, cleanup)
- **MCP tests**: Tool calling from agent to Paid, authorization checks

### Test Scenarios

| Scenario | Expected Result |
|----------|----------------|
| Create API-mode session, send message, receive streaming response | Response streams to browser in real-time, messages persisted |
| Create workspace session with project, send message | Container provisioned with worktree, agent has file access |
| Agent calls `list_projects` MCP tool | Tool returns user's projects, result persisted as tool message |
| Agent calls `trigger_agent_run` MCP tool | Agent run queued, confirmation returned to chat |
| Session idle for 30 minutes | Session transitions to 'idle', container destroyed |
| Re-open idle session | New container created, conversation history loaded |
| Cross-project session with 3 projects | Agent can reference all 3 projects' context |
| Token limit reached mid-conversation | Graceful message explaining limit, session stays readable |
| Unauthorized user tries MCP tool | Tool call rejected with permission error |

### Performance Validation

- API mode: First response token within 2 seconds
- Workspace mode: Container provision within 30 seconds, first response within 5 seconds
- Streaming: Chunk delivery latency under 100ms
- Concurrent sessions: Support 10 active sessions per account
- Idle reaper: Sessions cleaned up within 5 minutes of timeout

### Security Validation

- All chat endpoints require authentication
- Chat sessions scoped to account via RLS
- MCP tools authorized via Pundit policies
- Container network access restricted (only Paid MCP server + LLM APIs)
- No API keys or tokens exposed to browser
- Chat messages do not persist sensitive data (credentials, tokens)

## References

### Requirements & Standards

- AGENTS.md: All LLM calls must go through agent-harness; provider-specific logic belongs in agent-harness
- RDR-007: Agent CLI abstraction (agent-harness gem)
- RDR-004: Container isolation strategy
- RDR-006: Secrets proxy architecture

### Dependencies

- agent-harness 0.11.0+ (with chat transport, conversation manager)
- GitHub Models API (OpenAI-compatible endpoint)
- ActionCable (bundled with Rails)
- Docker API (existing container infrastructure)

### Research Resources

- GitHub Models API documentation: OpenAI-compatible REST format
- agent-harness source: `lib/agent_harness/text_transport.rb`, `lib/agent_harness/providers/adapter.rb`
- MCP specification: Model Context Protocol transport types (stdio, HTTP, SSE)
- Paid container provisioning: `app/services/containers/provision.rb`
