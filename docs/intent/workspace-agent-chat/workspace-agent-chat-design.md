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

`ChatSession` will persist an immutable execution-mode selection for started
sessions. `workspace_agent_chat` sessions require a ready workspace and a
runner/model that passes the mode, credential, project-policy, privacy, and
availability gates. Each turn creates a Paid-owned request record before a
stateless native CLI invocation. The invoker uses the current system prompt and
last 20 non-system messages within a 64 KiB UTF-8 framed budget, receives
streamed progress, and persists only final assistant content plus sanitized
provenance and reported usage.

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

## Implementation and verification plan

#5351 first writes failing focused specs for each `WORKSPACE-AGENT-CHAT-*`
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
