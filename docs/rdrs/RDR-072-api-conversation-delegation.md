# RDR-072: Delegate API Conversation Mechanics Through AgentHarness

## Metadata

- **Date**: 2026-09-24
- **Status**: Accepted
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

### Persistence Decision

Paid may adopt RubyLLM-managed supporting tables when they remove substantial
bookkeeping. Custom persistence is not a requirement: recreating library
behavior in adapters would undermine the simplification goal. Agent-harness
must remain usable without Rails; any Rails persistence integration is optional
and must not impose Active Record models on plain Ruby consumers.

Before adopting supporting tables, demonstrate tenant isolation, auditability,
and preservation of existing conversations, message links and pending approvals.
Document and rehearse migration and recovery, including completed tool effects.
Paid retains ownership of application authority and domain records even when
the library manages supporting storage. The specific tables and integration
contract remain implementation-design work. Retaining Paid's loop over a
normalized transport is still an acceptable outcome if delegation adds complexity.

### Provider Coverage Decision

Adopt incrementally by operation and provider as capability and behavior tests
pass. Complete provider parity is not a prerequisite for the first migration.
Preserve working execution paths for providers or operations not yet supported,
including CLI/subscription callers. Track each remaining migration or justified
retained path explicitly in the implementation issues opened after approval.

Unsupported capability must be visible to the caller. Keep capability-based
routing explicit; do not silently switch credentials or authentication modes,
or disguise a failed migrated request by replaying it through the old path.
Remove superseded code within each migrated scope once its replacement is
verified. Temporary coexistence across scopes is allowed; duplicate permanent
implementations of the same supported path are not the target.

### Retry and Accounting Decision

Agent-harness owns bounded retries of an individual provider request, using
RubyLLM where appropriate. Paid supplies retry limits and cancellation; the
harness must honor those controls across its internal attempts. Configure one
effective request-retry owner rather than multiplying harness and RubyLLM
retry loops. Authentication/configuration failures remain distinct from
transient failures and do not enter transient retry handling.

Paid owns runner changes and workflow recovery. When request retries are
exhausted, return a classified outcome to Paid so its existing eligibility,
credential, fallback and recovery policies determine what happens next.
Request retries and runner changes must preserve completed tool results;
neither authorizes replay of completed application side effects.

The harness reports individual attempts and any available usage, including
failed attempts, so Paid can attribute consumption without duplication. A new
outbound request is a new attempt; redelivery of an existing attempt record is
not. Paid owns durable accounting and budget enforcement. Stable attempt IDs,
restart recovery and idempotent persistence need a tested technical contract;
unknown usage must remain unknown rather than being recorded as zero.

### Loop Delegation Decision

Delegate the chat loop only when it demonstrably simplifies the maintained
system while preserving required behavior. Replacing Paid's loop is not a
mandatory destination. Keeping it over normalized harness transport is an
acceptable completed outcome, with the evidence and retained responsibilities
recorded in the design and closeout.

Compare removed sequencing, transcript and approval-resumption mechanics with
all new adapters, persistence glue and recovery code in both repositories.
Moving equivalent custom code upstream or reducing Paid's line count alone
does not establish simplification. Require behavior tests for authorization,
confirmation policy, budgets, resumption and side-effect recovery, plus a
reviewable account of reduced maintenance responsibilities and migration cost.
If those criteria are not met, retain the loop and complete the independently
useful transport, embedding, schema and usage improvements.

### Ownership

| Responsibility | Owner |
|---|---|
| Actor identity, Pundit checks, tenant context and tool visibility | Paid |
| Eligible runners, credentials, allowed models, fallback order and notices | Paid |
| Bounded retries of individual provider requests | Agent-harness, honoring Paid-supplied limits and cancellation |
| Runner changes, workflow recovery and durable usage attribution | Paid |
| Confirmation policy, selective auto-approval and two-phase drafts | Paid |
| Generic pending decisions and resumable tool sequencing | Harness where the loop-delegation criteria are met; otherwise Paid's retained loop |
| Protocols, schemas, streaming and normalized API errors | Harness contract backed by RubyLLM |
| Conversation identity, application message links and audit attribution | Paid |
| Optional supporting persistence schema and mechanics | RubyLLM where adopted; Paid verifies tenant isolation, migration and audit requirements |
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

These are accepted requirements. Implementation must map them into
existing LLD/EARS segments and add failing-first tests. This decision does not
change implemented EARS status or supersede RDR-028.

## Alternatives Considered

| Alternative | Assessment |
|---|---|
| Retain current implementations | Lowest migration risk, but retains patches and duplicated mechanics. |
| Call RubyLLM directly from Paid | Breaks the HLD's single execution interface. |
| Delegate transport, retain Paid's loop | Recommended first milestone; may remain the final boundary if loop adapters add more complexity than they remove. |
| Delegate transport and reusable loop mechanics | Adopt only when preserved behavior and net maintenance simplification are demonstrated, counting new adapters and persistence/recovery code. |
| Require eventual loop delegation regardless of demonstrated benefit | Rejected; retaining Paid's loop over normalized transport is an acceptable completed outcome. |
| Require custom persistence for all supporting state | Rejected as a blanket constraint; adapters may recreate the bookkeeping being removed. |
| Adopt RubyLLM-managed supporting tables selectively | Allowed where simplification is demonstrated and tenant isolation, auditability and migration requirements are met; Rails remains optional for harness consumers. |
| Require complete provider parity before any adoption | Rejected; migrate verified operation/provider scopes incrementally and preserve other working paths with explicit follow-up tracking. |
| Schedule every provider-request retry in Paid | Rejected; delegate bounded request retries to the harness while Paid retains runner changes, workflow recovery and accounting policy. |

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

**Docs-only now:** this accepted RDR ships no runtime behavior. Open implementation
issues in agent-harness and Paid after the RDR is merged.

Embedding, schema and transport adoption should ship as complete, tested
replacements within each migrated operation/provider scope. Other supported
paths can retain their current implementation while their migration is tracked.
Avoid permanent duplicate implementations and additional retry layers within
a migrated scope.

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
remaining gaps. Mark implemented only from that evidence. If the evaluation
supports retaining Paid's loop, record that supported outcome and align the
implementation issues; it is not an unfulfilled promise of eventual delegation.
Any other scope reduction requires an explicit recommendation and issue update.

## Technical Investigation

The architectural preferences are resolved above. The following investigations
must supply implementation evidence; they do not reopen those preferences or
claim that unverified library capabilities already exist.

1. Which supporting tables should Paid adopt, and what optional integration
   contract preserves stable tool IDs and resumption while keeping the harness
   usable without Rails? The permission to use library-managed persistence is
   resolved above; the technical mapping still requires investigation.
2. Establish the operation/provider/custom-endpoint capability matrix and
   explicit unsupported-capability outcomes. Incremental adoption with preserved
   working paths is decided above; the actual coverage requires verification.
3. Specify stable attempt identities, idempotent accounting and crash recovery
   across restarts and Paid-controlled runner switches. Retry ownership is
   resolved above; verify that limits/cancellation reach every internal attempt
   and completed tools are not replayed.
4. Evaluate loop delegation against the decided criteria: behavior preservation,
   net maintenance reduction across both repositories and migration cost.
   Document the evidence for delegation or retaining Paid's loop.

## Implementation Design Mapping

[`api-conversation-delegation`](../intent/api-conversation-delegation/api-conversation-delegation-design.md)
maps these investigations into implementation-ready ownership, persistence,
attempt/recovery, and loop-evaluation contracts. Its EARS claims deliberately
remain gaps until a verified `agent-harness` release containing #431 and the
protected Paid #3995 Codex subscription discovery/recovery compatibility are
installed and tested.

The mapping retains Paid's `ChatSession`/`ChatMessage` transcript IDs,
approval claims, actor/tenant authority, and durable accounting; optional
RubyLLM supporting tables may only supplement that state. It also defines the
attempt identity and aggregate cross-repository comparison required before a
later loop decision. This RDR's rollout guard remains docs-only: the mapping
does not authorize a dependency change, schema migration, or runtime routing.

## Sources

- [RubyLLM 2.0 release guide](https://github.com/crmne/ruby_llm/blob/v2.0.0/docs/_getting_started/whats-new-in-2-0.md)
- [Tool approvals and execution](https://rubyllm.com/tool-execution/)
- [Upgrade and persistence changes](https://rubyllm.com/upgrading/)
- [Error handling and model fallbacks](https://rubyllm.com/error-handling/)
- [API-mode chat specs](../intent/api-mode-chat/api-mode-chat-specs.md)
- [Tool confirmation specs](../intent/chat-tool-confirmation/chat-tool-confirmation-specs.md)
