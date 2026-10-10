# EARS Specs: API Conversation Transport Delegation

> Testable claims for RDR-072 transport adoption. Status markers: `[x]`
> implemented · `[ ]` active gap · `[D]` deferred.

- [x] **API-CONVERSATION-DELEGATION-001** — When Paid builds an API-mode chat
  turn for a migrated operation/provider scope, `ChatSessions::BuildLlmClient`
  SHALL build a single-candidate `AgentHarness::Api::ChatTransport` request
  (provider, protocol, runner credentials, normalized messages/tools) and
  translate its normalized result/classified error back to Paid's existing
  return and raise contract; it SHALL NOT call RubyLLM or a provider API
  directly, and a harness result SHALL NOT be granted authority to execute or
  approve an application tool. Each turn receives a Paid-owned durable request
  identity and one effective retry owner wired through by
  API-CONVERSATION-DELEGATION-003 below, while runner switching and workflow
  recovery remain owned entirely by `ChatSessions::FallbackLoop` at the Paid
  layer.
  *Tests:* `spec/services/chat_sessions/build_llm_client_spec.rb`.
  *Code:* `ChatSessions::BuildLlmClient::HttpClient#call`,
  `ChatSessions::BuildLlmClient::HttpClient#build_request`,
  `ChatSessions::BuildLlmClient::HttpClient#translate_result`.

- [x] **API-CONVERSATION-DELEGATION-002** — When a migrated transport reports
  request attempts, Paid SHALL persist every report exactly once by stable
  attempt ID and ordinal, attribute it to the initiating actor, chat session,
  originating message, runner, and provider, and aggregate reported usage
  without double counting. A project-backed session SHALL retain its project;
  a projectless session SHALL persist an account-scoped attempt and SHALL NOT
  discard a successful provider response. Missing usage SHALL remain unknown
  rather than be recorded as zero; a failed attempt with reported usage SHALL
  remain visible.
  `ChatSessions::BuildLlmClient::HttpClient#call` persists every
  `result[:attempts]` report through `ChatSessions::RecordTransportAttempt`
  before translating a successful, partial, or classified failed result. The
  retained loop supplies the actor and originating message when it builds the
  client, preserving runner/session attribution. The recorder's unique
  attempt identity and `token_usage_id` claim make report redelivery safe.
   *Tests:*
   `spec/services/chat_sessions/build_llm_client_spec.rb`,
   `spec/services/chat_sessions/record_transport_attempt_spec.rb`,
   `spec/services/billing/aggregate_tenant_usage_spec.rb`.
   *Code:* `ApiUsageAttempt`, `ChatSessions::RecordTransportAttempt`,
   `ChatSessions::BuildLlmClient::HttpClient`, `ChatSessions::FallbackLoop`,
   and `TokenUsageTracker` integration.

- [x] **API-CONVERSATION-DELEGATION-003** — When a process restarts, a request
  is cancelled, or Paid changes runner after a classified terminal result, the
  harness SHALL honor the supplied request bound and cancellation signal, and
  Paid SHALL either accept a matching durable attempt report or allocate a new
  outbound attempt. Neither recovery path SHALL replay a completed tool or
  multiply request retry loops. Paid SHALL supply two independent bounds, not
  one constant reused for both: a **read deadline**, the maximum time with no
  data on the stream, passed as `timeout: { read_seconds: ... }`; and a
  **request deadline**, a generous wall-clock cap on the whole outbound
  attempt that only terminates a request that is stuck in a way the read
  deadline cannot observe, passed as a monotonic cancellation signal. The
  request deadline SHALL be strictly longer than the read deadline, so a
  response still actively streaming data past the read deadline's duration
  SHALL NOT be cancelled by the request deadline.
  `ChatSessions::HarnessTransport` allocates a monotonic request sequence in
  Paid-owned session metadata and supplies that stable request identity, a
  single effective request-attempt limit, a `READ_DEADLINE`-based
  `read_seconds` inactivity timeout, and a separate `REQUEST_DEADLINE`-based
  monotonic cancellation signal to the public harness request contract.
  `REQUEST_DEADLINE` (10 minutes) is independent of, and longer than,
  `READ_DEADLINE` (60 seconds), so a model that is still streaming past 60
  seconds is not cancelled. A restarted delivery or runner fallback allocates
  a new request identity; persisted transcript rows, including completed tool
  results, are retained as the loop rebuilds its conversation, so the harness
  never executes a tool and Paid does not introduce a second request-retry
  loop.
  *Tests:* `spec/services/chat_sessions/harness_transport_spec.rb`,
  `spec/services/chat_sessions/fallback_loop_spec.rb`,
  `spec/jobs/chat_sessions/process_message_job_spec.rb`.
  *Code:* `ChatSessions::HarnessTransport`,
  `ChatSessions::FallbackLoop` recovery boundary.

- [x] **API-CONVERSATION-DELEGATION-004** — When a migrated chat turn contains
  read and write tools or resumes a pending confirmation, Paid SHALL retain
  RDR-028 authority: it SHALL recheck tenant context and Pundit authorization
  for the acting collaborator, atomically claim the Paid pending row, inject
  `confirmed: true` only after a human or eligible Paid auto-approval decision,
  persist denied results, and resume only after all required decisions settle.
  Satisfied by the retained loop recorded in
  API-CONVERSATION-DELEGATION-006: `AgentLoop` and `ResolveToolCall` implement
  these RDR-028 behaviors on top of the migrated transport; a harness result
  never originates approval from model arguments.
  *Tests:* `spec/services/chat_sessions/agent_loop_spec.rb`,
  `spec/services/chat_sessions/resolve_tool_call_spec.rb`,
  `spec/requests/chat_messages_spec.rb`.
  *Code:* `ChatSessions::AgentLoop`, `ChatSessions::ResolveToolCall`,
  `Tools::Registry`.

- [D] **API-CONVERSATION-DELEGATION-005** — When Paid adopts optional
  RubyLLM-managed supporting persistence, it SHALL preserve Paid
  `ChatSession`/`ChatMessage` transcript and external IDs, pending approvals,
  application tool links, audit attribution, and tenant isolation. Supporting
  tables SHALL enforce RLS for both reads and writes; their migration SHALL
  reconcile historical and pending state and prove recovery from a side effect
  whose result was not yet persisted.
  Deferred by the retained-loop outcome in API-CONVERSATION-DELEGATION-006:
  with `AgentLoop` and `ResolveToolCall` retained, no supporting tables are
  adopted and Paid's own records remain the only conversation persistence.
  Revisit only if a future loop-delegation proposal reopens the persistence
  contract, and then with the tests and migration work below.
  *Tests (when reopened):* `spec/migrations/adopt_api_conversation_supporting_tables_spec.rb`,
  `spec/models/api_conversation_supporting_record_spec.rb`,
  `spec/services/chat_sessions/recover_tool_result_spec.rb`.
  *Planned code:* migration generated by Rails, optional Paid Rails adapter,
  `ChatSessions::RecoverToolResult`.

- [x] **API-CONVERSATION-DELEGATION-006** — When the RubyLLM loop evaluation
  is complete, Paid SHALL retain its loop unless the public harness contract
  preserves behavior and reduces the aggregate adapters, persistence, and
  recovery mechanics across both repositories. The evaluation in
  `agent-harness` #448 found no durable caller-stable tool identity,
  plain-Ruby restart recovery, external dispatch boundary, bounded completion,
  or stable attempt identity, so Paid SHALL retain `AgentLoop` and
  `ResolveToolCall`. A runner fallback SHALL discard the failed attempt's own
  partial rows by id-scoped rollback, while retaining completed tool
  call/result rows so the fallback transcript cannot replay their side effects;
  rows persisted by a concurrent turn SHALL remain untouched. No loop
  API release, runtime flag, schema migration, or backup rehearsal is required
  for this retained-loop outcome; separately activated transport/accounting
  work remains subject to its own release gate and image verification.
  *Tests:* upstream
  `spec/ruby_llm_loop_delegation_evaluation_spec.rb`,
  `spec/services/chat_sessions/agent_loop_spec.rb`,
  `spec/services/chat_sessions/resolve_tool_call_spec.rb`,
  `spec/services/chat_sessions/send_message_spec.rb`.
  *Code:* `ChatSessions::AgentLoop`, `ChatSessions::ResolveToolCall`,
  `ChatSessions::FallbackLoop`.
