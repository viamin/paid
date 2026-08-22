# RDR-064: Container Agent Chat Mode

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-22
- **Status**: Draft
- **Type**: Architecture + Interactive Chat + Runner Execution
- **Priority**: P1
- **Related RDRs**: [RDR-007](RDR-007-agent-cli-abstraction.md) (Agent CLI Abstraction), [RDR-028](RDR-028-interactive-chat.md) (Interactive Chat), [RDR-037](RDR-037-containerized-multi-repo-chat.md) (Containerized Multi-Repo Chat Sessions), [RDR-041](RDR-041-subscription-runner-auth-lifecycle.md) (Subscription Runner Managed Auth Lifecycle), [RDR-058](RDR-058-execution-authority-network-and-isolation.md) (Execution Authority, Network Policy, and Isolation)
- **Related Intent**: TBD
- **Related Issues**: TBD. Before implementation, create an issue that adds `container_agent_chat` to `FeatureFlags::DEFINITIONS` and wires every runtime routing decision through `FeatureFlags.enabled?(:container_agent_chat, project:)` or the account-equivalent gate selected during implementation.
- **Related Tests**: TBD

## Problem Statement

Paid chat currently treats "chat-capable runner" as "Rails can call a chat-completions-compatible HTTP endpoint for this runner." That works for API-key-backed providers such as OpenRouter, MiniMax, and z.ai when their endpoint supports the expected protocol, but it excludes runners whose useful credential lives in a CLI login or local agent session, such as Claude Code, Codex, OMP, Cursor, Gemini CLI, and similar agent tools.

This distinction is not really "subscription vs. API key." MiniMax and z.ai can be subscription products while still exposing API keys. The real distinction is transport:

- **HTTP chat transport**: Rails holds a bearer secret and calls a chat API.
- **Container agent transport**: the selected agent CLI runs inside the chat workspace container and uses its own native auth, tools, and execution model.

Paid already provisions chat containers and already runs agent CLIs in containers for agent runs, but interactive chat does not yet use that execution path for model turns.

## Decision

Add a **Container Agent Chat Mode** for workspace chat sessions. In this mode, the selected runner's CLI is executed inside the chat session's container through `agent_harness`, and the resulting text is persisted as the assistant reply.

Container agent chat is a session/message execution mode, not a property implied only by runner choice. Users may choose fast HTTP chat for API-backed runners when they do not need workspace-agent behavior. Runners whose practical auth is CLI/session based, such as Claude Code and Codex OAuth/subscription entries, must use container agent chat because Rails has no chat API credential to call directly.

The first version is intentionally plain:

- workspace chats only;
- text output only;
- CLI-native tools are allowed;
- Paid structured tool calls are not interpreted from the CLI output;
- Paid write-tool confirmation applies only to Paid-structured tools in HTTP chat mode, not to actions the CLI agent performs inside the workspace container.

This mode complements the existing HTTP chat mode rather than replacing it.

## Goals

- Let chat use runners whose practical auth is CLI/session based.
- Reuse existing chat container lifecycle and agent-harness runner execution instead of inventing a separate provider API.
- Make the transport difference explicit in runner/chat capability selection.
- Preserve existing HTTP chat behavior and structured Paid tool confirmation.
- Keep v1 small enough to ship and evaluate before adding structured tool parity.

## Non-Goals

- Do not parse arbitrary CLI prose into Paid tool calls in v1.
- Do not require upstream `agent_harness` changes for v1.
- Do not make inline-only chats run arbitrary CLI agents without a workspace container.
- Do not promise Paid's write-tool confirmation covers CLI-native file, shell, MCP, or provider tools.
- Do not build persistent interactive CLI sessions in v1; each chat turn may be a stateless CLI invocation.
- Do not silently switch a user from HTTP chat into container agent chat during fallback.

## Capability Model

Replace the current implicit chat eligibility check with explicit chat transport capabilities.

| Capability | Meaning | Examples |
|---|---|---|
| `http_chat` | Rails can call a chat-completions-compatible HTTP API for the runner. | OpenAI-compatible API-key runners, Anthropic API-key runners |
| `container_agent_chat` | Paid can run the runner CLI inside a chat container and capture text output. | Claude Code, Codex, OMP, Cursor, Gemini CLI, Copilot CLI |

Runner billing model is not part of this capability. A paid subscription exposed through an API key is still `http_chat`; a CLI login or local credential store is `container_agent_chat`.

Fallback selection must use the requested chat transport and session shape:

- inline-only chat may use `http_chat`;
- workspace chat may use `http_chat` or `container_agent_chat`;
- Claude Code, Codex, and other CLI/session-auth runners use `container_agent_chat`;
- API-backed runners may use either `http_chat` or `container_agent_chat` when both capabilities are available;
- fallback must stay within the active chat mode unless the user explicitly changes mode;
- a runner enabled for chat but lacking both capabilities is configuration-invalid or hidden from chat selection.

## Proposed Design

Add a `ChatSessions::ContainerAgentClient` that satisfies the same narrow interface the existing `AgentLoop` expects:

```ruby
def call(conversation, tools: nil, on_chunk: nil)
  # returns:
  {
    content: "...",
    model: "...",
    tokens_input: 0,
    tokens_output: 0,
    tool_calls: []
  }
end
```

The client:

1. Ensures the chat session has a ready workspace container, provisioning or reopening through existing chat container services when needed.
2. Flattens the bounded chat conversation into a single prompt.
3. Runs the selected runner through `agent_harness` inside the chat container.
4. Streams available stdout/progress text to the chat UI through the existing `on_chunk` callback.
5. Returns the final text to `AgentLoop`, which persists the normal assistant message.
6. Returns no structured tool calls in v1.

Prompt flattening should include:

- the current system prompt;
- recent user and assistant messages;
- tool-result messages only as prior context text;
- a clear instruction that the agent is running in the workspace container and may use its own CLI tools.

## Tool Semantics

Container agent chat has two tool worlds:

- **CLI-native tools**: tools the selected agent provides inside the container, such as shell, file edits, MCP, or provider-specific capabilities.
- **Paid structured tools**: tools surfaced through `Tools::Registry` and governed by Paid's confirmation model.

In v1, container agent chat uses CLI-native tools only. Paid does not parse CLI output into structured tool requests and does not approve or deny CLI-native actions after the fact.

V1 container agent chat is a workspace-agent mode: CLI-native file and shell tools may read and mutate the chat workspace according to the selected runner's normal container permissions. This is why the mode is limited to workspace chats, guarded by a feature flag, and labeled separately from HTTP chat.

This must be visible in UI copy. A user selecting container agent chat should understand that the agent is operating in the workspace container with its own tool model.

## Security And Isolation

Container agent chat inherits the chat workspace container boundary and the selected runner's network/auth requirements. The implementation must:

- run only for workspace chat sessions;
- use the existing chat container provisioning/reopen/close lifecycle;
- use the same credential materialization path agent runs use for the selected runner where possible;
- log the selected runner, transport mode, container id, and command status without logging secrets;
- keep existing tenant checks around chat sessions and messages.

Because CLI-native tools are not mediated through Paid structured tool confirmation, this mode should be opt-in and clearly labeled.

## Rollout Guard

Use a feature flag:

- **Flag**: `container_agent_chat`
- **Default**: off
- **Enablement surface**: account/project or internal operator-controlled rollout for workspace chat sessions
- **Rollback**: disable the flag; existing chats continue to render history, but new turns route only through HTTP chat
- **Implementation issue**: the issue listed in Related Issues must add the flag definition and route runtime checks through `FeatureFlags.enabled?(:container_agent_chat, project:)` or the account-equivalent gate selected during implementation
- **Cleanup criteria**: keep the flag until fallback behavior, runner selection, container lifecycle, error surfaces, and audit logging are covered by tests and closeout review

## Implementation Plan

1. Add explicit chat capability predicates for `http_chat` and `container_agent_chat`.
2. Update chat runner selection/fallback to filter by session capability and transport.
3. Add a user-visible chat mode choice for workspace chats: fast HTTP chat or container agent chat.
4. Add `ChatSessions::ContainerAgentClient`.
5. Route selected container-agent runners through that client from `ChatSessions::BuildLlmClient` or a small replacement builder.
6. Add minimal streaming and final-output persistence.
7. Add UI labeling for agent mode.
8. Add service/request specs for runner eligibility, fallback, provisioning, and final message persistence.

## Open Questions

- Should v1 use one stateless CLI invocation per chat turn, or preserve provider sessions when a runner supports them?
- Which existing container exec helper is the smallest safe reuse point for chat turns?
- Should container-agent chat be selectable per message or per session?
- How much stdout/stderr should be persisted versus streamed only?
