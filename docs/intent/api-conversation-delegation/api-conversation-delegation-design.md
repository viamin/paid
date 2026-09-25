---
parent: PAID
prefix: API-CONVERSATION-DELEGATION
---

# Low-Level Design: API Conversation Transport Delegation

> Implementation design for [RDR-072](../../rdrs/RDR-072-api-conversation-delegation.md).
> It refines the existing [API-mode chat](../api-mode-chat/api-mode-chat-design.md)
> and [tool-confirmation](../chat-tool-confirmation/chat-tool-confirmation-design.md)
> contracts without activating a runtime migration.

## Scope and rollout boundary

This segment adopts a public, normalized API-chat transport from
`agent-harness` after viamin/agent-harness#431 is released and verified. The
first migration replaces only a verified operation/provider scope; it does not
delegate the chat loop. `ChatSessions::AgentLoop`, `ChatSessions::ResolveToolCall`,
`ChatSession`, and `ChatMessage` remain the source of current runtime behavior
until a later decision meets the loop-delegation evidence below.

The rollout guard is **docs-only**. No feature flag, initializer change,
dependency update, supporting table, or routing change is permitted by this
segment. A dependent implementation must amend RDR-072 with its exact flag or
configuration gate, default, enablement owner, rollback action, and removal
criteria before it can send production traffic through the new transport.
Embedding adoption is a separate operation and neither gates nor is evidence
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
