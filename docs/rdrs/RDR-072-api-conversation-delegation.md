# RDR-072: Delegate API Conversation Mechanics Through AgentHarness

## Metadata

- **Date**: 2026-09-24
- **Status**: Draft
- **Type**: Integration architecture and ownership
- **Priority**: P2
- **Related RDRs**: [RDR-007](RDR-007-agent-cli-abstraction.md), [RDR-028](RDR-028-interactive-chat.md), [RDR-037](RDR-037-containerized-multi-repo-chat.md), [RDR-064](RDR-064-container-agent-chat-mode.md)

## Problem Statement

Paid owns provider message/tool formatting, streaming adaptation, a chat tool
loop, approval resumption, and usage aggregation. It also supplies embedding
transport patches in its initializer and a generated container script. These
mechanics duplicate library capabilities and make provider changes expensive
to maintain in the control plane.

RubyLLM 2.0 adds explicit conversation steps, tool approvals, persisted
resumption, provider/protocol separation, and attempt-level usage tracking.
Embeddings and structured output predate 2.0; adopting them is related cleanup,
not evidence that this release introduced them.

## Evidence and Current Intent

The inspected Paid checkout resolves RubyLLM 2.0.0 and agent-harness 0.37.5 at
`6e83b041168969e4eb5acb4441e3b35033dca0a1`. RubyLLM is declared for the model
registry; its presence does not mean Paid chats use its execution engine. The
inspected harness library has no RubyLLM integration.

| Current surface | Candidate responsibility to delegate |
|---|---|
| `ChatSessions::BuildLlmClient::HttpClient` | Provider-specific conversation/tool encoding and response/stream normalization |
| `ChatSessions::AgentLoop` | Generation/tool sequencing, pending-call bookkeeping, transcript reconstruction |
| `ChatSessions::ResolveToolCall` | Generic approval/denial state and resumption mechanics |
| `TokenUsageTracker`, chat token aggregation | Provider usage normalization and pricing for covered API requests |
| Initializer embedding patch, `Knowledge::EmbeddingRunner` | Duplicated embedding HTTP transport and error classification |
| Session summaries, context-intake questions | Fence/quote stripping and JSON extraction for schema-capable paths |

The [HLD](../high-level-design.md#approach-all-llm-calls-through-one-interface)
and [harness integration design](../intent/agent-harness-integration/agent-harness-integration-design.md)
require application LLM calls through agent-harness. Preserve that boundary.
This proposal does not authorize direct RubyLLM calls from Paid services or
substitute RubyLLM for containerized coding agents or Temporal.

## Recommendation

Adopt RubyLLM behind public agent-harness contracts incrementally. Start with
embeddings and normalized API chat transport. Evaluate delegation of the chat
loop after those contracts demonstrate Paid's required behavior.

Paid owns application authority and persisted domain records. Agent-harness
owns a provider-neutral execution contract and translates RubyLLM results and
errors into that contract. RubyLLM supplies API protocols and reusable
conversation mechanics inside that implementation.

Prefer application-supplied persistence or serializable conversation state.
Do not make RubyLLM Active Record models an accidental harness requirement.
If resumption requires RubyLLM-owned tables, compare migration cost and tenant
isolation explicitly before finalizing the loop decision. Retaining Paid's
loop over a normalized transport is an acceptable outcome.

### Ownership

| Responsibility | Owner |
|---|---|
| Actor identity, Pundit checks, tenant context and tool visibility | Paid |
| Eligible runners, credentials, allowed models, fallback order and notices | Paid |
| Confirmation policy, selective auto-approval and two-phase drafts | Paid |
| Generic pending decisions and resumable tool sequencing | Harness contract, using RubyLLM where suitable |
| Protocols, schemas, streaming and normalized API errors | Harness contract backed by RubyLLM |
| Conversation identity, application message links and audit attribution | Paid |
| Reported attempts, tokens and provider cost calculations | Harness contract for calls it executes |
| Budgets, CLI/proxy reconciliation and infrastructure costs | Paid |
| Containers, egress controls and secrets proxy | Existing Paid infrastructure |

An approval is an application authorization decision. A provider attempt is
one outbound model request. A chat turn may contain several attempts and tool
calls. Preserve these distinctions in the public contract.

### Required Behavior

- Approval never originates from model arguments. Recheck authorization at
  execution, including after resumption or a runner switch.
- Claim concurrent approval resolutions atomically. Resume only after required
  decisions settle; record denied calls as tool results.
- Preserve mixed read/write batches, eligible auto-approval, draft creation
  followed by confirmation, and retryable draft-confirmation failures.
- Specify recovery when a tool side effect succeeds but result persistence
  fails. Resumption does not guarantee exactly-once external effects; use tool
  idempotency or explicit reconciliation before replay.
- Preserve SSE, ActionCable and JSON contracts, application message IDs,
  reconnect behavior, empty-response handling and budget soft stops.
- Paid supplies eligible fallback candidates and per-candidate credentials.
  Request retries must not replay completed tools or multiply nested retry
  loops. Distinguish auth/configuration failures from rate limits.
- Preserve unknown usage/pricing separately from zero. Attribute each reported
  attempt once; distinguish provider-reported charges from Paid estimates.
- Keep CLI/subscription paths. Schema-dependent callers check capabilities;
  do not silently switch authentication modes to obtain structured output.

These are proposed acceptance requirements. Implementation must map them into
existing LLD/EARS segments and add failing-first tests. This Draft does not
change implemented EARS status or supersede RDR-028.

## Alternatives Considered

| Alternative | Assessment |
|---|---|
| Retain current implementations | Lowest migration risk, but retains patches and duplicated mechanics. |
| Call RubyLLM directly from Paid | Breaks the HLD's single execution interface. |
| Delegate transport, retain Paid's loop | Recommended first milestone; may remain the final boundary if loop adapters add more complexity than they remove. |
| Delegate transport and reusable loop mechanics | Preferred target if approval, persistence and retry contracts can be demonstrated. |
| Adopt RubyLLM Rails tables wholesale | Requires explicit assessment of tenant RLS, historical messages and application links; not the initial recommendation. |

## Non-Goals

- Replacing CLI providers, Temporal, the secrets proxy, model selection policy,
  or all Paid accounting.
- Introducing an RDR process in agent-harness. A design issue and maintained
  upstream API documentation suffice unless maintainers choose otherwise.
- Replacing knowledge version/freshness ranking with semantic reranking.
  That is a separate quality experiment with cost and latency implications.
- Adding batches, hosted research, media APIs, provider-hosted tools or prompt
  caching simply because RubyLLM exposes them.

## Rollout Guard

**Docs-only now:** this draft ships no runtime behavior. Open implementation
issues in agent-harness and Paid after the RDR is approved.

Embedding, schema and transport adoption should ship as complete, tested
replacements in their scoped paths. Avoid permanent dual implementations and
additional retry layers.

Loop adoption is blocked on a finalized, merged decision specifying persistence
and rollout. If staged runtime exposure is necessary, update this section
before implementation with the exact flag/config key, default, enablement
surface, owner, rollback action and removal criteria. Do not migrate pending
conversations until recovery tests prove decisions and completed tool effects
survive. Data changes require backup, rehearsal and rollback under Paid's
database safety rules. Reverting a gem is not a persistence rollback.

## Implementation and Validation

Use paired upstream capability and Paid adoption issues. Upstream closure is
insufficient: verify a published, installable release containing the contract,
then verify host and agent image versions. Preserve current Codex subscription
discovery/recovery behavior on every dependency update; coordinate Paid #3995.

Run upstream contract tests and Paid behavior tests covering cross-tenant
requests, custom proxies/headers, interrupted streams, transient/auth failures,
mixed tool batches, concurrent approvals, deny/resume, crash after a side effect,
budget exhaustion and unknown/zero usage. Verify historical transcripts and
pending confirmations wherever persistence changes. Compare deleted mechanics
with added adapter code rather than counting moved code as simplification.

Closeout records delegated and retained responsibilities, versions, tests and
remaining gaps. Mark implemented only from that evidence. A narrower target
requires an explicit recommendation and issue-scope update.

## Open Decisions

1. Can the harness support persistence-neutral resumption with stable tool IDs
   and cancellation, or are RubyLLM-owned records required?
2. Which providers/custom endpoints support each operation, and how are
   unsupported capabilities surfaced without silent fallback?
3. What attempt identities and retry ownership prevent duplicate usage and
   tool replay across restarts and Paid-controlled runner switches?
4. Does loop delegation remove enough complexity to justify migration beyond
   the normalized transport milestone?

## Sources

- [RubyLLM 2.0 release guide](https://github.com/crmne/ruby_llm/blob/v2.0.0/docs/_getting_started/whats-new-in-2-0.md)
- [Tool approvals and execution](https://rubyllm.com/tool-execution/)
- [Upgrade and persistence changes](https://rubyllm.com/upgrading/)
- [Error handling and model fallbacks](https://rubyllm.com/error-handling/)
- [API-mode chat specs](../intent/api-mode-chat/api-mode-chat-specs.md)
- [Tool confirmation specs](../intent/chat-tool-confirmation/chat-tool-confirmation-specs.md)
