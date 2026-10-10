# RDR-072 Acceptance Audit — 2026-10-10

## Scope and conclusion

This final umbrella audit follows the [RDR Closeout
Checklist](closeout-checklist.md) for viamin/paid#4013 (continuation request
#3, generation 981706336efd). The prior closeout
([2026-10-05](audit-report-2026-10-05-rdr-072.md)) kept the epic open on two
completion dependencies: viamin/paid#4125 (API-CONVERSATION-DELEGATION-002
attempt-report persistence) and viamin/paid#4126
(API-CONVERSATION-DELEGATION-003 request identity, bounds, and recovery).
Both have since shipped — #4125 in PR viamin/paid#4131 and #4126 in PR
viamin/paid#4133.

RDR-072 is **Implemented**. Every acceptance criterion in the retained scope
has shipped code and passing test evidence; no required gaps remain. The
retained loop over normalized harness transport is the accepted final outcome,
and viamin/paid#4013 closes on this evidence.

## Verified behavior (code and test evidence)

| RDR requirement | Code evidence | Behavior evidence |
| --- | --- | --- |
| Production attempt-report persistence (#4125 / PR #4131) | `app/services/chat_sessions/build_llm_client.rb:173` calls `persist_attempts(result)` before `translate_result`; `:180-191` persists every `result[:attempts]` report through `ChatSessions::RecordTransportAttempt`. The only production call site, `app/services/chat_sessions/fallback_loop.rb:21-25`, passes `message: transport_attempt_message`; all three hosts supply it (`send_message.rb:113`, `resolve_tool_call.rb:37`, `resume_rate_limited.rb:53-55`). | `spec/services/chat_sessions/build_llm_client_spec.rb` — "persists every reported attempt with the live chat attribution" (including a redelivered duplicate) and "persists account-level attempts without discarding a projectless chat response". |
| Exactly-once attribution/accounting | Unique `attempt_id` index (`db/schema.rb:439`, `idx_api_usage_attempts_idempotency`); `record_transport_attempt.rb:31-33` uses `create_or_find_by!`; `record_billable_usage` (`:62-75`) claims the ledger row under `with_lock` guarded by `token_usage_id.present?`. `ApiUsageAttempt` validates one owner and complete-or-unknown usage. | `spec/services/chat_sessions/record_transport_attempt_spec.rb` — failed-attempt billing, ordinal-change redelivery not re-billed, missing usage stays unknown (no zero-valued ledger row), non-USD charges retained, harness-estimated provenance. `spec/services/billing/aggregate_tenant_usage_spec.rb` — tenant aggregation without double counting. |
| Bounds, cancellation, restart/fallback recovery (#4126 / PR #4133) | `app/services/chat_sessions/harness_transport.rb:8-14` — one-attempt bound, `READ_DEADLINE` (60 s inactivity) independent of and shorter than `REQUEST_DEADLINE` (10 min wall clock); `:44-57` allocates a persisted monotonic request sequence under a session lock so a restarted delivery gets a new identity; `DeadlineCancellation` (`:65-74`) is a monotonic cancellation signal. `fallback_loop.rb:63-70` discards only the failed attempt's own rows by id, retaining completed tool call/result rows. | `spec/services/chat_sessions/harness_transport_spec.rb` — durable identity and bound, new identity after restart, no cancellation while streaming past the read deadline, cancellation at the request deadline, deadline independence. `spec/services/chat_sessions/fallback_loop_spec.rb` — completed tool calls/results survive a failed-runner discard. `spec/jobs/chat_sessions/process_message_job_spec.rb:283` — fallback notice and continuation. |
| Retained-loop contracts (RDR-028 authority) | `ChatSessions::AgentLoop` and `ChatSessions::ResolveToolCall` remain the authority boundary (`@spec API-CONVERSATION-DELEGATION-004` annotations at `agent_loop.rb:42`, `resolve_tool_call.rb:46`); approval never originates from model arguments. | `spec/services/chat_sessions/agent_loop_spec.rb`, `spec/services/chat_sessions/resolve_tool_call_spec.rb`, `spec/requests/chat_messages_spec.rb` — approval, denial/resume, mixed batches, authorization rechecks. |
| Embedding transport (#4015, re-verified) | `app/services/knowledge/embeddings/generate.rb:103` and `app/services/knowledge/embedding_runner.rb:220` call `AgentHarness.embed`; no RubyLLM transport patch remains in `config/initializers/` (RubyLLM is model-catalog-only per `config/application.rb`). | Included in prior closeout suites; no regression in this audit's suites. |
| Protected dependency provenance | `Gemfile` pins `gem "agent-harness", "0.44.9"` exactly; `Gemfile.lock` resolves 0.44.9 with checksum. 0.44.9 contains the public API chat contract, preserves classified provider errors (viamin/agent-harness#472, Paid #3995 compatibility), and retains the Codex subscription discovery/recovery fixes. | `bundle exec ruby -e 'puts Gem.loaded_specs.fetch("agent-harness").version'` printed `0.44.9` on the audit host. |

## EARS reconciliation

All six claims in
[`docs/intent/api-conversation-delegation/api-conversation-delegation-specs.md`](../intent/api-conversation-delegation/api-conversation-delegation-specs.md)
are reconciled: 001–004 and 006 `[x]` implemented; 005 `[D]` deferred by the
retained-loop outcome (no supporting tables adopted, so Paid's own records
remain the only conversation persistence). No `[ ]` gap markers remain in the
segment; `bin/coherence-check.mjs` reports valid arrow references and full
`@spec` coverage for the segment's claims.

## Stale status reconciled by this audit

- `docs/rdrs/RDR-072-api-conversation-delegation.md`: status
  Partially Implemented → Implemented; rollout-guard dependency evidence
  updated 0.44.3 → 0.44.9; Implementation Status and closeout rewritten.
- `docs/rdrs/README.md`: RDR-072 row → Implemented.
- `docs/intent/api-conversation-delegation/api-conversation-delegation-design.md`:
  operation/provider matrix row for durable attempt-report persistence →
  `migrated`; epic-audit rows for #4018/#4020 updated; the 2026-10-05
  "remaining gaps" and closeout sections reconciled to the completed state.
- `docs/arrows/index.yaml`: segment status PARTIAL → OK, audited 2026-10-10.

## Remaining work and deployment prerequisites

No remaining code work in the retained scope. Two deployment-time
prerequisites (already mandated by the RDR rollout guard, restated here as
the exact release steps):

1. On the release host, verify `bundle exec ruby -e 'puts
   Gem.loaded_specs.fetch("agent-harness").version'` prints `0.44.9`.
2. Inspect or rebuild the agent image and confirm API-mode chat does not route
   through it or the secrets proxy; retain that verification record with the
   release. (Docker is unavailable in this audit environment, so this check
   cannot be executed here. API-mode chat executes in the Rails host process,
   so no agent-image rebuild is required for the chat path itself.)

Successor scope, intentionally outside this RDR: CLI/subscription chat
authentication modes remain on their existing retained path until a successor
RDR verifies their public harness contracts.

## Verification record

The audit environment ran `bundle install`, `yarn install --frozen-lockfile`,
and `bin/rails db:prepare` (PostgreSQL via `DATABASE_URL`). The affected
suite — `spec/services/chat_sessions`,
`spec/services/billing/aggregate_tenant_usage_spec.rb`,
`spec/services/llm/generate_session_summary_spec.rb`,
`spec/services/knowledge/context_intake/generate_questions_spec.rb`,
`spec/requests/chat_messages_spec.rb`, `spec/jobs/chat_sessions`,
`spec/requests/chat_sessions_spec.rb`, `spec/channels/chat_channel_spec.rb` —
ran **588 examples, 0 failures**.
