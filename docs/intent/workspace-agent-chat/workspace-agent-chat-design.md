---
parent: PAID
prefix: WORKSPACE-AGENT-CHAT
---

# Low-Level Design: Workspace Agent Chat

> Proposed implementation intent for [RDR-064](../../rdrs/RDR-064-container-agent-chat-mode.md).
> It is not runtime authority until RDR-064 is Accepted, this handoff is
> finalized, and #5351 is admitted.

## Purpose and boundary

Workspace agent chat is a third chat execution concern: it reuses the shipped
workspace lifecycle from RDR-037, but invokes a selected runner CLI through
`agent_harness` in that workspace. API-mode chat continues to own HTTP/API
transport and Paid structured tool confirmation; it is not a fallback for this
mode. Container provisioning/reopen continues to own workspace lifecycle.

## Proposed shape

`ChatSession` will persist the execution mode, credential/billing intent,
privacy requirement, execution authority, and tool-confirmation semantics
authorized at creation. These choices are immutable for started sessions;
runner or project-policy changes may reject a route but cannot re-derive or
relax them during a later turn, retry, or fallback. `workspace_agent_chat` sessions require a ready workspace and a
runner/model that passes the mode, credential, project-policy, privacy, and
availability gates. Each turn creates a Paid-owned request record before a
stateless native CLI invocation. The invoker keeps the complete system prompt
and current user message, then includes the newest optional history within
20 non-system messages total and a 64 KiB UTF-8 framed budget. Required system
content, current input, and their framing must fit together; otherwise the
turn fails before invocation without truncating them. Older optional history
is omitted oldest first, while the full readable transcript remains persisted.
The invoker receives
streamed progress, enforces a 60-second no-progress read deadline and a
10-minute monotonic whole-turn deadline, and persists only final assistant
content plus sanitized provenance and reported usage.

The execution service will compose existing workspace provisioning/reopen,
credential materialization, network policy, and `agent_harness` contracts; it
will not add a Paid CLI wrapper, direct provider request, or CLI-output parser.
Existing per-session serialization and durable request identity will make
cancellation/recovery terminal and non-replaying. A stale workspace can reopen
only before an invocation starts; uncertain execution requires explicit user
retry.

## Authority and rollout

Native CLI tools use the runner's existing workspace-container permissions.
They are clearly labeled and outside `Tools::Registry` confirmation. API-mode
structured tools retain their current confirmation authority. Runner/model
fallback stays in the selected mode and preserves privacy, credential/billing,
and execution authority; no compatible route is an actionable failure.

`FeatureFlags.enabled?(:container_agent_chat, ...)` will be default off and
must guard selection, creation, execution, fallback, and recovery. Disabling
it preserves transcripts but rejects incompatible new workspace-agent turns;
the system never changes a session mode implicitly.

## Decisions & Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Execution-mode lifetime | Persist the selected mode and authorized credential/billing, privacy, execution-authority and tool-confirmation choices on `ChatSession` for the life of a started session. | Infer the mode from the runner for each turn; switch modes during fallback. | A session's mode determines its authentication and billing intent, execution and native-tool authority, privacy behavior, and transcript interpretation. Persisting it makes those properties explicit and prevents a retry or fallback from silently changing them. See [RDR-064](../../rdrs/RDR-064-container-agent-chat-mode.md#recommendation). |
| CLI invocation lifetime | Run one stateless native CLI invocation per turn. | Reuse a persistent provider CLI session in V1. | Stateless turns reuse the existing workspace lifecycle while avoiding unspecified provider-session, credential-renewal, cancellation, and recovery state. A persistent CLI session needs a separate design unless it can preserve the same authority and recovery contract. See [RDR-064](../../rdrs/RDR-064-container-agent-chat-mode.md#recommendation). |
| Conversation context | Keep the complete system prompt and current message; omit older optional history oldest first to fit at most 20 non-system messages and 64 KiB including UTF-8 framing. Reject before invocation if required content and framing together exceed the budget; retain the full readable transcript. | Send the entire transcript; truncate required content; retain an unbounded prompt cache. | Required content must fit as a whole even when its individual messages fit separately. The bound constrains invocation size without changing essential input or deleting user-visible history. |
| Native-tool authority | Let the selected runner's native CLI tools operate under its existing workspace-container permissions, separately labeled from Paid structured tools. | Parse CLI output into `Tools::Registry` calls; apply Paid structured-tool confirmation to native tools. | Native CLI output is not a safe authority boundary, and parsing it would duplicate provider behavior. Preserving the distinction leaves API-mode structured confirmation unchanged and makes workspace mutation authority clear before session creation. See [RDR-064](../../rdrs/RDR-064-container-agent-chat-mode.md#capabilities-authority-and-fallback). |
| Fallback behavior | Allow only candidates compatible with the persisted mode, effective privacy, credential/billing intent, and execution authority; otherwise fail before prompt transmission. | Cross-mode fallback to API chat; silently relax privacy or credentials to complete a turn. | A compatible fallback can restore availability without changing what the user authorized. When none exists, an actionable failure is safer and more truthful than silently changing the runner, model, billing/authentication, privacy, or tool semantics. See [RDR-064](../../rdrs/RDR-064-container-agent-chat-mode.md#capabilities-authority-and-fallback). |

## Implementation and verification plan

Issue #5351 first writes failing focused specs for each `WORKSPACE-AGENT-CHAT-*`
claim, adds a permanent system flow for labeled mode selection/history
preservation, then implements the flag, persistence, eligibility, invoker, and
recovery behavior. It must prove actual supported CLI execution in the
devcontainer without recording credentials. #5352 reconciles the shipped
revision, test evidence, and live operational evidence. #4707 remains the
privacy-policy owner; #4971/#4972 remain isolated API and host-cutoff owners.

## Open questions

- Which runner set has an upstream `agent_harness` contract sufficient for the
  initial internal rollout? #5351 must make unsupported runners ineligible.
- Should a later persistent CLI session have a separate RDR/LLD, rather than
  extending the V1 stateless contract? Yes unless its recovery/credential
  semantics can be specified without widening authority.
