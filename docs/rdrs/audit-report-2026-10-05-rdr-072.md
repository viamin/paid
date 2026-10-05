# RDR-072 Closeout Audit — 2026-10-05

## Scope and conclusion

This audit follows the [RDR Closeout Checklist](closeout-checklist.md) for
viamin/paid#4020 and `Tracks #4013`. RDR-072 is **Partially Implemented**.
It must not close #4013: API-CONVERSATION-DELEGATION-002 and -003 remain
unmet in the live API-key chat path.

The accepted retained-loop outcome is complete. `ChatSessions::AgentLoop` and
`ChatSessions::ResolveToolCall` remain the application authority boundary;
this is a supported result of RDR-072 rather than deferred loop delegation.

## Shipped evidence

| RDR requirement | Code evidence | Behavior evidence |
| --- | --- | --- |
| Normalized API-key chat transport while retaining Paid runner policy | `app/services/chat_sessions/build_llm_client.rb:128-203` constructs a single `AgentHarness::Api::ChatTransport` candidate and translates its result/error contract. | `spec/services/chat_sessions/build_llm_client_spec.rb` verifies messages, tools, streaming, classified errors, endpoint, and output-limit behavior. |
| Tenant-safe, idempotent attempt-accounting mechanics | `app/models/api_usage_attempt.rb:3-65` validates one owner and complete-or-unknown usage; `app/services/chat_sessions/record_transport_attempt.rb:19-74` idempotently creates an attempt and records usage once. | `spec/services/chat_sessions/record_transport_attempt_spec.rb` and `spec/services/billing/aggregate_tenant_usage_spec.rb` cover redelivery, unknown versus zero usage, and pricing provenance. |
| Approval, denial, and fallback authority remain in Paid | `app/services/chat_sessions/fallback_loop.rb:20-70` changes runners only after a classified harness failure and deletes only the failed attempt's message rows. | `spec/services/chat_sessions/agent_loop_spec.rb`, `spec/services/chat_sessions/resolve_tool_call_spec.rb`, and `spec/requests/chat_messages_spec.rb` cover approval, denial/resume, and fallback behavior. |
| Host and container embedding transport use agent-harness | `app/services/knowledge/embeddings/generate.rb:101-115` calls `AgentHarness.embed`; `app/services/knowledge/embedding_runner.rb:204-220` embeds through the agent-image script. | The affected generator and embedding specs are included in the RDR-072 validation command below. |
| Protected dependency provenance | `Gemfile:73-81` and `Gemfile.lock` pin `agent-harness` 0.44.3. The RDR rollout guard records the RubyGems release, source commit `85c4bc3`, and Paid #3995 compatibility rationale. | `bundle exec ruby -e 'puts Gem.loaded_specs.fetch("agent-harness").version'` printed `0.44.3` on the audit host. |

## Missing behavior and required completion dependency

`ChatSessions::BuildLlmClient::HttpClient#call` generates a new request UUID
at `app/services/chat_sessions/build_llm_client.rb:151-176`, then returns only
the translated response at lines 194-203. It does not consume
`result[:attempts]` or invoke `ChatSessions::RecordTransportAttempt`. It also
does not receive a durable Paid request identity, cancellation signal, or
deadline. Consequently the isolated accounting mechanics cannot attribute
actual API-chat attempts and restart recovery is not defined.

A focused child issue must be filed before closure, with these acceptance
criteria:

1. Give each outbound API-chat request a Paid-owned stable identity and pass
   its retry limit, deadline, and cancellation signal to agent-harness.
2. Persist every harness `result[:attempts]` report through
   `ChatSessions::RecordTransportAttempt` exactly once, including failed and
   unknown-usage reports.
3. Specify and test restart and runner-fallback recovery so completed tools
   are not replayed and a new outbound request gets a new attempt identity.

Until that child exists and is complete, #4020 and #4013 remain open. No
temporary rollout guard is removed: the API-key runner-selection boundary is
still required by RDR-072 while CLI/subscription and recovery scopes are not
verified.

## Verification record

The audit environment ran `bundle install`, `yarn install --frozen-lockfile`,
and `bin/rails db:prepare`. The affected-suite command was:

```sh
bundle exec rspec spec/services/chat_sessions \
  spec/services/billing/aggregate_tenant_usage_spec.rb \
  spec/services/llm/generate_session_summary_spec.rb \
  spec/services/knowledge/context_intake/generate_questions_spec.rb \
  spec/requests/chat_messages_spec.rb spec/jobs/chat_sessions \
  spec/requests/chat_sessions_spec.rb spec/channels/chat_channel_spec.rb
```

Docker is not installed in this environment (`docker: No such file or
directory`), so no real agent-image/container execution can be represented as
passed. The host API-chat path does not enter an agent container; before a
deployment, the release maintainer must still rebuild or inspect the agent
image and confirm that API-mode chat does not route through it or the secrets
proxy, as required by the RDR rollout guard.
