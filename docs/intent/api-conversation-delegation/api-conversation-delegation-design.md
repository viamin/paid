---
parent: PAID
prefix: API-CONVERSATION-DELEGATION
---

# Low-Level Design: API Conversation Transport Delegation

> Implementation design for [RDR-072](../../rdrs/RDR-072-api-conversation-delegation.md).
> It refines the existing [API-mode chat](../api-mode-chat/api-mode-chat-design.md)
> and [tool-confirmation](../chat-tool-confirmation/chat-tool-confirmation-design.md)
> contracts. Paid #4016 activates only the verified API-key transport scope;
> it does not delegate the chat loop.

## Scope and rollout boundary

This segment adopts a public, normalized API-chat transport from
`agent-harness` after viamin/agent-harness#431 is released and verified. The
first migration replaces only a verified operation/provider scope; it does not
delegate the chat loop. `ChatSessions::AgentLoop`, `ChatSessions::ResolveToolCall`,
`ChatSession`, and `ChatMessage` remain the source of current runtime behavior
until a later decision meets the loop-delegation evidence below.

RDR-072 now authorizes this non-staged scope through the existing
`Runner#enabled_for_chat?` API-key selection gate. A chat-enabled API-key
runner uses the normalized transport by default; CLI and subscription runners
remain outside the scope. The release maintainer owns enablement and rolls back
by deploying the preceding Paid release after draining in-flight API requests.
No feature flag, initializer change, supporting table, or schema migration is
introduced. Embedding adoption is separate and neither gates nor is evidence
for API-chat transport or loop adoption.

## Current mapping and retained authority

| Current surface | Retained or delegated responsibility |
| --- | --- |
| `ChatSession` / `ChatMessage` | Paid-owned canonical session, stable external transcript/message IDs, actor attribution, historical transcript, tool-call links, pending confirmation state, and audit evidence. |
| Chat/session Pundit policies and `TenantContext` | Paid establishes tenant context and authorizes every HTTP, SSE, Cable, queued, tool, and recovery entry point. A queued action acts as its current collaborator, never implicitly as `created_by`. |
| `ChatSessions::AgentLoop` | Retained initially: transcript reconstruction, tool sequencing, soft budget stops, persisted streaming messages, and mixed read/write batches. It may consume normalized harness responses. |
| `ChatSessions::ResolveToolCall` / `Tools::Registry` | Retained: atomic pending-row claim, authorization at dispatch, confirmation policy, selective auto-approval, two-phase draft confirmation, denial result, and no-resume-until-settled behavior. |
| `ChatSessions::BuildLlmClient::HttpClient` | Migration candidate: provider protocol encoding, streaming normalization, tool schema encoding, normalized response/error shape, and request-level usage. Paid does not call RubyLLM directly. |
| `ChatSessions::FallbackLoop` and jobs | Paid retains candidate selection, credentials, runner switches, notices, durable workflow/job recovery, and the existing no-replay rules for persisted work. |
| `TokenUsageTracker` and Paid budget records | Paid retains durable, idempotent accounting, budgets, estimates, CLI/proxy reconciliation, and infrastructure cost. Harness reports individual request attempts and provider-reported usage where available. |

The harness contract receives a Paid-supplied execution context containing the
account-scoped conversation ID, current actor ID, originating chat-message ID,
runner/candidate identity, and opaque cancellation handle. These are
attribution and correlation fields, not authority grants: Paid still resolves
credentials, runs Pundit checks, applies tool visibility, and routes secrets
through existing proxy infrastructure. A harness result may not create,
approve, or execute an application tool on its own.

RDR-069's future shared-question conversations strengthen this rule: a session
creator is not a substitute for the collaborator who sent or resolved a
message. The existing RDR-028 confirmation semantics remain authoritative.

## Persistence and migration contract

RubyLLM-managed supporting tables are optional. They are allowed only for
library-private conversation-step, pending-decision, or attempt bookkeeping
that demonstrably replaces Paid bookkeeping. They do not replace these Paid
records: `ChatSession`, `ChatMessage`, application tool identifiers/results,
approval claims/decisions, `TokenUsage`, audit events, or budget records.
`agent-harness` must keep this persistence adapter optional so plain-Ruby
consumers do not need Rails or Active Record.

If supporting tables are adopted, Paid's adapter must add and validate an
`account_id` ownership boundary (or an equivalent immutable foreign-key path),
foreign-key it to the Paid conversation where appropriate, enable and force
RLS, and use `paid_current_account_id()` in both `USING` and `WITH CHECK`.
The migration must preserve account/project consistency and prevent a row from
being re-parented across tenants. The supporting rows must carry the Paid
conversation external ID and the related Paid message/tool-call external ID so
operators can reconstruct history without treating library IDs as public API.

Before any write cutover, the implementation must snapshot and rehearse:

1. backfill/read-only mapping of historical messages, including assistant tool
   calls and tool results, with counts and per-session reconciliation;
2. pending approval mapping that preserves the original Paid pending row and
   its atomic claim; library state is derived support, never the sole approval
   authority;
3. crash recovery after a tool side effect but before its result is persisted;
   recovery checks the tool's idempotency key or performs explicit
   reconciliation before any replay; and
4. rollback that stops new transport traffic while retaining readable Paid
   transcripts and reconciliation metadata. Reverting a gem is not a data
   rollback.

Historical messages stay readable through current Paid records throughout a
dual-read or backfill period. A migration cannot silently omit unknown legacy
state or convert it to an empty result.

## Request attempts, retries, and recovery

An **attempt** is one outbound provider request. A chat turn may have many
attempts, and an attempt has no authority to replay a completed tool. Paid
allocates an immutable attempt ID before invoking the harness. The ID includes
the Paid turn/message identity and a monotonically increasing request sequence;
the same ID is reused only when delivery of that already-recorded attempt is
redelivered, while any new outbound request receives a new ID. A runner switch
is a Paid recovery action and starts a new attempt sequence under the same turn.

Paid supplies `max_request_attempts`, retry classification, deadline, and a
cancellation signal to the harness. Harness owns retries inside that one
request only, checks cancellation before each internal attempt and while
streaming, and returns a classified terminal result after the bound is reached.
Neither RubyLLM nor Paid may add a second uncoordinated retry loop for the same
request. Authentication and configuration failures are terminal for the
candidate; rate-limit and transient failures remain distinguishable for Paid's
runner policy.

The harness reports each internal provider attempt with its stable parent
attempt ID, ordinal, runner/provider/model identity, outcome, timestamps, and
reported usage/cost when available. Paid persists these reports idempotently
on `(attempt_id, ordinal)` before aggregation. Duplicate reports do not add
tokens or cost. Failed attempts are recorded when usage is reported. Missing
usage remains `unknown`, never zero. After process restart, Paid reloads the
durable attempt record and either accepts a matching terminal report or creates
a new outbound attempt; it never guesses whether an unrecorded provider call
succeeded.

## Loop-delegation decision method

Loop delegation is a later, evidence-based decision, not a target assumed by
this LLD. A proposal must pass all of the following before activation:

1. **Behavior parity:** executable tests preserve tenant/actor checks,
   tool visibility, manual and eligible auto-approval, mixed batches,
   two-phase drafts, atomic concurrent claims, denial/resume, transcript IDs,
   SSE/Cable/JSON reconnect behavior, soft budgets, cancellation, and unknown
   usage.
2. **Side-effect recovery:** tests cover a crash after a side effect before
   result persistence and prove reconciliation/idempotency prevents replay of
   completed tools across restart and runner switch.
3. **Net maintenance reduction:** a review table counts deleted and added
   adapters, persistence integration, recovery/idempotency, and tests in both
   Paid and `agent-harness`. Moving equivalent custom code upstream or merely
   reducing Paid LOC is not a reduction. The proposal must name the owner of
   every remaining responsibility and show fewer maintained mechanisms in
   aggregate.
4. **Migration cost and operability:** the proposal includes schema/RLS/audit
   evidence, historical/pending-conversation reconciliation, backup and
   rollback rehearsal, host verification, and rebuilt-agent-image verification.

The closeout records the comparison, versions, capability matrix, retained
unsupported paths, and test evidence. If any criterion fails, retain Paid's
loop over normalized transport and record that as the completed outcome.

## Capability and deployment evidence

Each adoption issue publishes an operation/provider matrix with the explicit
result for every scope: `migrated`, `retained`, or `unsupported`. Unsupported
means a visible capability outcome; it never silently changes credentials,
authentication mode, endpoint, or falls back through the old path after a
migrated request fails. CLI/subscription paths remain retained until their
contract is independently verified.

Before enabling a verified scope, pin an installable `agent-harness` release
that includes #431 **and** retains the Codex subscription discovery/recovery
fixes protected by Paid #3995. Verify the resolved host bundle and rebuild the
agent image; then run an in-container check against the rebuilt image and
secrets-proxy route. The deployment evidence records the immutable gem ref,
image digest, capability matrix, and rollback route.

## Implementation record (viamin/paid#4016)

**Release evidence:** `agent-harness` 0.44.3, pinned in `Gemfile`/`Gemfile.lock`
(exact, non-yanked, non-prerelease; [RubyGems](https://rubygems.org/gems/agent-harness/versions/0.44.3),
[release](https://github.com/viamin/agent-harness/releases/tag/agent-harness/v0.44.3)).
It supersedes 0.41.0, the release that delivered the `AgentHarness::Api::ChatTransport`
contract (viamin/agent-harness#433 / PR viamin/agent-harness#441, "Normalize
API Chat Transport, Tools and Streaming"), and 0.44.0, which Paid #3995
verified as the first release retaining the Codex subscription
discovery/recovery fixes after reconciling the durable-pin removal. No agent
image rebuild was required for this change: the chat path runs in the Rails
host process, not inside agent containers.

**Scope shipped — operation/provider matrix:**

| Scope | Result | Notes |
| --- | --- | --- |
| API-mode chat, Anthropic API-key runners | `migrated` | `ChatSessions::BuildLlmClient::HttpClient` now builds a single-candidate `AgentHarness::Api::ChatTransport` request (`provider: :anthropic, protocol: :messages`) instead of calling `AgentHarness::TextTransport` directly. |
| API-mode chat, OpenAI-compatible runners (OpenAI, OpenRouter, MiniMax, z.ai, z.ai-coding, DeepSeek, Mistral, xAI, Inception) | `migrated` | Single candidate with `provider: :openai, protocol: :chat_completions`; MiniMax's `chat_base_url` and z.ai/z.ai-coding's `chat_max_tokens` (16,384) pass through unchanged as `candidate[:endpoint]` / `request[:max_output_tokens]`. |
| Runner selection, credential resolution, free-model-policy re-resolution | `retained` | Unchanged in `ChatSessions::BuildLlmClient` outside `HttpClient`. |
| Runner fallback eligibility, notices, rate-limit resumption (`ChatSessions::FallbackLoop`/`FallbackRunners`/`MarkRateLimited`) | `retained` | `HttpClient` raises the same `AgentHarness::*Error` subclasses as the old transports (translated from the harness's classified `result[:error]`), so this policy layer needed no changes. Multi-candidate/`fallback:` support in `ChatTransport` is intentionally unused — one call is one provider attempt, matching "transient model fallback alone cannot replace this policy." |
| CLI/subscription chat runners | `retained` (unsupported path, unchanged) | Chat still requires an API-key runner (`BuildLlmClient.usable_runner?`); this was true before this migration and is not a new restriction. |
| Chat loop sequencing, tool dispatch, approval resumption (`ChatSessions::AgentLoop`, `ResolveToolCall`, `Tools::Registry`) | `retained` | Out of scope per the Loop Delegation Decision; `HttpClient`'s public `#call(conversation, tools:, on_chunk:)` contract is unchanged so `AgentLoop`'s reflection-based kwarg detection and streaming replay keep working unmodified. |
| Request attempt identity, retry-limit/deadline/cancellation plumbing, durable attempt-report persistence (API-CONVERSATION-DELEGATION-002/003) | `unsupported` (tracked gap) | Each `HttpClient#call` issues an ephemeral request UUID and defaults to one harness attempt (`retry.max_attempts: 1`); Paid does not yet supply a stable recovery identity, deadline, or cancellation token, and does not persist per-attempt harness reports. Left for a follow-up issue. |

**Tests:** `spec/services/chat_sessions/build_llm_client_spec.rb` (black-box
against `AgentHarness::Api::ChatTransport`, including normalized request,
tool-transcript, interrupted-stream, classified-error, MiniMax endpoint, and
z.ai output-limit coverage) plus the full existing `spec/services/chat_sessions/`,
`spec/jobs/chat_sessions/`, `spec/requests/chat_messages_spec.rb`,
`spec/requests/chat_sessions_spec.rb`, and `spec/channels/chat_channel_spec.rb`
suites (575 examples), run unmodified against the new transport to confirm
SSE/Cable/JSON contracts, message IDs, fallback notices, and rate-limit
resumption are unchanged.

## Epic audit (viamin/paid#4013, 2026-10-01)

Final umbrella audit of RDR-072 against shipped behavior, tests, and this
arrow. Evidence per child:

| Child | Outcome | Evidence |
| --- | --- | --- |
| #4014 contracts | Verified | This design + EARS segment defines the ownership, persistence, attempt/recovery, and loop-evaluation contracts; indexed in `docs/arrows/index.yaml`. |
| #4015 embedding patches | Verified | Host path `Knowledge::Embeddings::Generate#request_embeddings` and the containerized script in `Knowledge::EmbeddingRunner` both call `AgentHarness.embed`; no RubyLLM transport patch remains in `config/initializers/` (RubyLLM stays model-catalog-only per `config/application.rb`). |
| #4016 chat translation | Verified | `ChatSessions::BuildLlmClient::HttpClient` builds `AgentHarness::Api::ChatTransport` requests and translates normalized results/classified errors; `agent-harness` 0.44.3 pinned in `Gemfile`/`Gemfile.lock` per the rollout guard; matrix above. |
| #4017 structured results | Verified | `Llm::GenerateSessionSummary` and `Knowledge::ContextIntake::GenerateQuestions` use `operation: :schema` with `Llm::TextMode.enabled?` capability routing; CLI/subscription callers keep the text path (no silent auth-mode switch). |
| #4018 attempt accounting | Verified | `ApiUsageAttempt` (forced RLS, unique `attempt_id`, unknown-usage validations) + idempotent `ChatSessions::RecordTransportAttempt` + `Billing::AggregateTenantUsage` integration; `record_transport_attempt_spec.rb` and `aggregate_tenant_usage_spec.rb` cover exactly-once, redelivery, unknown-vs-zero, and non-USD provenance. |
| #4019 loop outcome | Verified | Loop retained per the agent-harness #448 evaluation (EARS 006); `FallbackLoop#discard_partial_attempt` rolls back only the failed attempt's rows by id so a runner fallback cannot replay stale partial work. |
| #4020 close RDR-072 | **Blocked** | See remaining gaps below. |

Test evidence (this audit): 464 examples ran across `spec/services/chat_sessions/`,
`spec/services/billing/aggregate_tenant_usage_spec.rb`,
`spec/services/llm/generate_session_summary_spec.rb`,
`spec/services/knowledge/context_intake/generate_questions_spec.rb`,
`spec/requests/chat_messages_spec.rb`, and `spec/jobs/chat_sessions/`; 463
passed. The single failure (`build_system_prompt_spec.rb:477`) is an audit
environment artifact, not a regression: it appears only when the test database
is seeded with global style guides (the two rejected lines are verbatim from
`db/seeds/style_guides.rb`), while CI prepares the test database with
`db:create db:schema:load` and no seeds. `bin/coherence-check.mjs` reports
this segment's only uncovered `[ ]` spec as API-CONVERSATION-DELEGATION-003.

**Remaining gaps that block closing RDR-072 (via #4020):**

1. API-CONVERSATION-DELEGATION-003 is an active gap: the live API-key chat
   path issues ephemeral request UUIDs with `retry.max_attempts: 1`, supplies
   no Paid-owned attempt identity, deadline, or cancellation, and discards the
   harness's `result[:attempts]` reports (no production caller of
   `ChatSessions::RecordTransportAttempt` yet). The matrix above tracks this
   as "left for a follow-up issue", but no follow-up issue number is recorded
   anywhere in this repository. RDR-072's provider-coverage decision requires
   each remaining migration to be tracked explicitly in an implementation
   issue; that issue must exist and be referenced here before #4020 closes
   the RDR.
2. The RDR-072 closeout itself (status flip to Implemented in the RDR and
   `docs/rdrs/README.md`, plus the delegated/retained-responsibility record)
   has not been written; it should consume this audit table.

No runtime code changes are required by this audit; EARS 004 was reconciled
to implemented (retained loop, tests annotated) and EARS 005 to deferred
(retained-loop outcome), matching the evaluated outcome in EARS 006.
