# RDR-064: Container Agent Chat Mode

> Proposed on 2026-11-25. This record recommends a decision; it does not
> authorize runtime work until the owner accepts this exact revision and the
> LID handoff is Final.

## Metadata

- **Date**: 2026-08-22
- **Status**: Proposed
- **Type**: Architecture + Interactive Chat + Runner Execution
- **Priority**: P1
- **Related RDRs**: [RDR-007](RDR-007-agent-cli-abstraction.md),
  [RDR-028](RDR-028-interactive-chat.md),
  [RDR-037](RDR-037-containerized-multi-repo-chat.md),
  [RDR-041](RDR-041-subscription-runner-auth-lifecycle.md),
  [RDR-058](RDR-058-execution-authority-network-and-isolation.md), and
  [RDR-072](RDR-072-api-conversation-delegation.md)
- **Related Intent**: [Workspace Agent Chat LLD](../intent/workspace-agent-chat/workspace-agent-chat-design.md)
  and [EARS](../intent/workspace-agent-chat/workspace-agent-chat-specs.md)
- **Related Issues**: #5350 (this decision and handoff), #5351 (implementation,
  blocked by this decision becoming Final), #5352 (closeout); #4971 (isolated
  API chat), #4972 (host-inference cutoff), #4707 (privacy/fallback), and
  closed #4968 (isolated text foundation)
- **Related Tests**: planned `WORKSPACE-AGENT-CHAT-*` coverage in the linked
  EARS; existing API isolation coverage is not evidence of CLI workspace turns.

## Problem and evidence

Two isolated paths are easy to conflate but have different authority and
credentials:

| Surface | Verified current evidence | Does not provide |
| --- | --- | --- |
| API chat inference | #4971 remains open, but merged [#5115](https://github.com/viamin/paid/pull/5115) moved API-chat inference to a disposable text container and merged [#5210](https://github.com/viamin/paid/pull/5210) repaired its isolated stream/tool boundary. `API-CONVERSATION-DELEGATION-001` through `-004` describe the retained Paid loop, tool confirmation, attempt accounting, cancellation, and no host fallback. | A CLI running in the durable chat workspace, CLI-native tools, or subscription/session authentication. |
| Workspace lifecycle | RDR-037 intent, `CHAT-CONTAINER-PROVISIONING-*`, `CHAT-SESSION-REOPEN-*`, and `MULTI-REPO-CHAT-001` through `-004` show persisted capability state, background provision/reopen, clone-manifest restore, and container-only workspace tools. | Model turn execution through a selected runner CLI. |
| Host-inference enforcement | #4972 remains open and owns the final global cutoff. | Evidence that every application text caller, including a future CLI chat mode, is already covered. |
| Privacy/fallback | #4707 remains open, blocked by `viamin/agent-harness#557`; its 2026-11-21 owner evidence records an unresolved OpenCode ZDR configuration contract. | Permission to claim provider enforcement or relax privacy when a compatible route is unavailable. |

Closed #4968 is a reusable isolated text foundation, not acceptance of either
API-chat delivery or workspace CLI behavior. The issue queue currently shows
no assignee for #4971, #4972, #4707, #5350, #5351, or #5352. This record does
not reassign them: #4971/#4972 retain isolation ownership, #4707 retains
privacy ownership, #5351 owns this mode's implementation, and #5352 owns final
criterion closeout.

## Recommendation

Add a **workspace agent chat** execution mode. It runs the selected runner's
native CLI through `agent_harness` inside the existing chat workspace
container. It is not an HTTP transport, and a disposable API-inference
container is not an implementation substitute.

The mode is selected and persisted on the **session**, not per message. A
session has one execution authority, authentication/billing intent, native-tool
semantics, and transcript interpretation. New turns cannot silently replace
those properties. V1 uses one **stateless CLI invocation per turn**; provider
session reuse is deferred until it has a separately specified recovery and
credential contract.

The invocation receives a bounded rendering of the persisted transcript: the
complete system prompt and current user message, then as many of the newest
non-system messages as fit, up to 20 non-system messages including the current
message, within a 64 KiB UTF-8 prompt budget after structural message framing.
If the system prompt, current user message, and their required framing together
exceed that budget, the turn is rejected before invocation with an actionable
error. Required content is never truncated; older optional messages are omitted
oldest first to meet both bounds. Earlier history remains
readable in Paid and is not silently discarded. This is a conversation-context
bound, not an authorization or tool-result replay mechanism.

### Capabilities, authority, and fallback

`http_chat` means the configured runner/model can serve Paid's API-mode chat
contract. `workspace_agent_chat` means the configured runner CLI can run in a
ready chat workspace using its own supported authentication and tools. A
runner may advertise both capabilities, but selection requires the active
session mode, workspace state, supported credential materialization, project
policy, model availability, and effective privacy policy.

Fallback is mode preserving. It may choose only a compatible runner/model with
the same mode, effective privacy requirement, authentication/billing intent,
and execution authority. It cannot turn a CLI/subscription turn into API-key
HTTP inference, turn an API session into a CLI session, or use host inference.
If no compatible candidate exists, Paid records and surfaces an actionable
failure without sending the prompt.

CLI-native shell, file, MCP, and provider tools operate only under the selected
runner's existing workspace-container permissions. Paid does not parse native
CLI output into `Tools::Registry` calls and Paid structured-tool confirmation
does not approve or deny those native actions. Existing HTTP-mode structured
tool confirmation remains unchanged. The UI must label this distinction before
session creation.

### Turn, credential, and recovery contract

Paid persists the final assistant message and sanitized turn provenance
(mode, runner, effective model, workspace/container identity, request identity,
terminal outcome, and actual usage when reported). Progress may stream while a
turn runs but raw stdout/stderr and credentials are not transcript records.
Unknown usage remains unknown; Paid must not invent token values.

The turn uses only the existing scoped credential-materialization and
container/network policy paths. Rails receives neither a reusable CLI login nor
a broader provider secret. A credential, privacy, configuration, or authority
failure is terminal for that candidate and cannot trigger a cross-mode retry.

V1 applies a 60-second no-progress read deadline and a 10-minute monotonic
whole-turn deadline. Cancellation reaches the harness/container, records one
terminal cancelled outcome, and releases turn resources. The durable request
identity and per-session turn serialization prevent duplicate assistant replies.
After a stopped or stale workspace, Paid may reuse the existing reopen path and
clone-manifest recovery before starting an unstarted turn; it must never replay
a possibly started CLI invocation. If recovery cannot prove that no invocation
started, the user receives an explicit retry choice.

### Rollout guard

`container_agent_chat` is default **off**. #5351 must add it to
`FeatureFlags::DEFINITIONS` and gate every workspace-agent session creation,
turn route, fallback route, and resume/recovery route through the approved
account/project scoped flag API. Initial rollout is internal, selected
account/project workspace sessions only; inline sessions are ineligible.

Disabling the flag stops new workspace-agent sessions and rejects new turns in
existing workspace-agent sessions with a mode-unavailable explanation. It does
not delete, rewrite, or reroute their history. A user may explicitly create a
new eligible session in another mode; rollback never silently switches an
existing session's runner, billing/authentication, privacy, or execution
authority.

## Alternatives

| Alternative | Rejection |
| --- | --- |
| Treat the disposable API-inference container as workspace agent chat | It has no durable workspace or native-tool authority. |
| Infer mode from runner or switch mode on fallback | It obscures authentication, billing, tool, and workspace authority. |
| Persistent CLI sessions in V1 | It introduces provider-session, credential-renewal, cancellation, and recovery state before the basic mode is proven. |
| Parse CLI prose into Paid structured calls | It makes untrusted prose an authority boundary and duplicates provider behavior. |

## Load-bearing assumptions

| Assumption | Status and verification | Consequence if false |
| --- | --- | --- |
| `agent_harness` can run each supported CLI in a chat workspace with scoped credentials, streaming, cancellation, and classified outcomes. | Pending: #5351 must prove it in the devcontainer for each enabled runner; unsupported runners remain ineligible. | Do not enable that runner or emulate it in Paid. |
| The existing reopen lifecycle can prove an invocation did not start before replay. | Pending: #5351 focused recovery test and #5352 runtime closeout. | Require explicit user retry; never automatic replay. |
| Effective privacy can be enforced or honestly declared for the selected native route. | Pending: #4707 / `agent-harness#557`. | Block privacy-required route before prompt transmission. |

## Owner decision and delivery handoff

**Owner acceptance is pending.** The owner must explicitly accept this exact
repository revision (commit SHA or PR head) and any conditions in the #5350
thread. This Proposed record is not Accepted or Final, and #5351 remains
blocked. The unresolved decisions are deliberately visible rather than implied
by merge or issue status.

After acceptance, #5350 must update the linked LLD/EARS from proposed to
accepted implementation intent, record the written finalization answers, and
make this RDR Final before #5351 may start runtime work. #5351's smallest
credible evidence plan is: permanent system tests for mode labeling and
history/rollback preservation; focused service tests for eligibility, fallback,
context bounds, privacy, cancellation, and recovery; and devcontainer CLI
evidence for each enabled runner. #5352 must perform criterion-level closeout
against the resulting EARS and live operating evidence.
