---
parent: PAID
prefix: CHAT-API
---

# Low-Level Design: API-Mode Interactive Chat

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills brownfield LID coverage for the shipped API-mode portion of
> [RDR-028](../../rdrs/RDR-028-interactive-chat.md).

## Purpose

Paid ships an interactive chat surface for account-scoped and optionally
project-scoped conversations that run through API-backed LLM calls, persist the
conversation as `ChatSession`/`ChatMessage` records, stream progress to the
browser, execute read-only MCP tools inline, and pause write tools for human
confirmation.

This segment covers the behavior that is implemented today for the inline/API
path:

- chat session creation, listing, and detail routes
- persisted conversation messages
- JSON, SSE, and ActionCable streaming surfaces
- tool-call orchestration for read-only and write tools
- token usage attribution and surfaced totals
- write-tool pause/resume behavior in the chat loop

## Scope Boundary

This segment is intentionally limited to the shipped API-mode behavior from
RDR-028. Workspace/container mutation mode is **not** covered here as shipped
behavior.

- Background workspace provisioning, capability upgrades, reopen flows, clone
  manifests, and container-only mutation tools belong to
  `docs/intent/containerized-multi-repo-chat/`,
  `docs/intent/chat-container-provisioning/`, and
  `docs/intent/chat-session-reopen/` under RDR-037.
- Per-tool execution guards that require `confirmed: true` for specific
  mutating tools belong to `docs/intent/chat-tool-confirmation/`.
- The planned normalized transport, optional supporting persistence, request
  attempts, and evidence-based loop-delegation boundary belong to
  `docs/intent/api-conversation-delegation/` under RDR-072. That segment is
  docs-only; it does not change the shipped RDR-028 loop or confirmation
  authority described here.

The API-mode chat loop may still accept legacy `mode=workspace` inputs for
backward compatibility, but that compatibility shim is not evidence that the
workspace/container behavior from RDR-028 shipped here; it is only a route into
the RDR-037 capability model.

## Existing Foundations

The implemented behavior builds on:

- account-scoped chat persistence (`ChatSession`, `ChatMessage`)
- account/project authorization via Pundit policies
- `agent_harness` chat clients constructed through `ChatSessions::BuildLlmClient`
- Paid MCP tool definitions in `Tools::Registry`
- per-request token accounting in `TokenUsageTracker`

## Current State

### Managed free-model chat pool

`FreeModels::SelectChatModel` selects concrete OpenRouter models for runners
using `model_policy: "free"`. The existing daily `FreeModels::SyncJob` supplies
the catalog; selection queries that catalog at each client build. Eligible
models are active, unexpired, synced and free, support tools and text output,
and meet `QualityFilter`'s 128,000-token minimum. Routing aliases under
`openrouter/`, operator-disabled rows, below-quality-bar rows, project-excluded
models, disallowed upstream providers, and runner-rate-limited models are
excluded. An eligible session model is retained for continuity; otherwise the
highest catalog capability score wins, with model ID as the deterministic tie
breaker. Empty pools raise `LlmClientConfigurationError`; paid defaults and
automatic routers are never substitutes. The selected model is reported by
the client and response and saved on API sessions without mutating the runner's
agent-run tier mappings.

API client construction, fallback selection, container chat plans, and
chat-only runner tests share the selector. Mixed agent/chat runner tests retain
the agent tier test behavior. Free chat selection is separate from automatic
retry: existing chat runner fallback and rate-limit handling remain in force.

All attached primary and reference projects constrain the pool. API clients
revalidate selection before every request, including follow-up tool rounds,
so newly attached project context cannot bypass those restrictions. The current
agent-harness API transport cannot transmit OpenRouter data-collection/ZDR
options: managed free API chat therefore rejects confidential and restricted
context before transmission with an actionable configuration error. Container
chat uses the most restrictive attached project's routing controls; Pi/OMP
container chat also rejects sensitive context until those runners consume the
routing metadata. Empty or privacy-incompatible free pools are excluded from fallback candidates so a
later configured runner remains reachable.

The API-mode chat surface is implemented and exposed across both HTML and API
entry points.

What ships today:

- sessions default to inline-only (`container_capability: none`) unless the
  caller explicitly requests workspace capability
- `ChatMessagesController` supports JSON and SSE request/response flows
- `ChatChannel` plus `ChatSessions::ProcessMessageJob` support ActionCable
  progress events for the browser UI
- `ChatSessions::AgentLoop` executes read-only tools inline and persists
  pending write-tool confirmations without letting the model self-authorize
  mutations
- `ChatSessions::ResolveToolCall` atomically resolves pending confirmations and
  resumes the loop only when the final pending confirmation has been settled
- rate-limited sessions are resumed by a maintenance sweep after their recorded
  reset time; a renewed rate limit records the new reset time, while another
  provider error creates a durable transcript notice and requires a user to
  correct the runner configuration or resend rather than retrying a permanent
  authentication or configuration failure indefinitely
- `ChatSessions::BuildLlmClient` raises the OpenAI-compatible transport
  `max_tokens` cap to 16,384 for direct-provider z.ai chat runners so GLM
  responses are not truncated by the transport default
- the transcript hides leading `<think>` reasoning blocks from assistant
  messages during streaming and on reload while retaining the original
  content and escaping ordinary HTML
- MiniMax chat uses its OpenAI-compatible `/v1` endpoint; CLI runners retain
  the configured Anthropic endpoint
- token usage for chat turns is recorded on `token_usages` and surfaced back
  through the chat UI/API totals
- `Tools::RepoReadClientResolver` resolves repo-read tool calls (`grep_repo`,
  `read_repo_file`, `list_repo_tree`, `search_issues`) against the project's
  own GitHub credential first (App installation token, or PAT when the
  project has no installation), falling back to the chatting user's active
  token only when the project has no usable credential — so a single chatting
  user's personal GitHub Code Search/rate-limit quota is not exhausted ahead
  of the project's own quota bucket
- `get_pull_request_details` includes a sanitized `auto_merge` section that
  exposes only project-scoped diagnostic facts about the latest known
  auto-merge state. Persisted merge-permission cooldown state is preferred
  when present, and current PR mergeability / check status are used as a
  fallback when no persisted attempt history exists.
- the default chat guidance (`ChatSessions::BuildSystemPrompt#base_identity`
  fallback, the seeded `chat.system_prompt` template, and the `grep_repo`
  tool description) directs repo code discovery to `search_code` (Paid's
  knowledge base) first, `read_repo_file` when the path is known, and
  `grep_repo` only when knowledge search is unavailable or stale, or when
  exact GitHub Code Search behavior is required — `grep_repo` is backed by
  GitHub Code Search and spends its small code_search rate-limit bucket, so
  routine chat exploration must not exhaust it (#3391).
- `Tools::Registry.chat_definition_for` calls each tool class's
  `description_for(session:)` hook (default: the static `description`) when
  building chat-advertised tool definitions, so a tool's framing can shift
  with session/project state without hiding it. `grep_repo` uses this to
  demote its own description to a fallback-only note once the session's
  current project has a ready knowledge base, steering the model to
  `search_code` for ordinary code discovery instead of exhausting shared
  GitHub Code Search rate limits (#3392).

## What this is not

- **Not workspace/container mutation behavior.** That shipped behavior is owned
  by the RDR-037 chat segments, not this RDR-028 brownfield backfill.
- **Not tool-specific authorization semantics.** Those remain in the individual
  tool segments such as `chat-tool-confirmation`.
- **Not unrestricted cross-project execution.** Every chat/tool path remains
  account-scoped and Pundit-checked.
