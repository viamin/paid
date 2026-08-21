# EARS Specs: API-Mode Interactive Chat

> Testable claims for the shipped API-mode portion of interactive chat. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **CHAT-API-001** — When a user creates or opens an API-mode chat session,
  the system SHALL persist and expose an active inline chat session with a
  system prompt and session/message routes, defaulting to
  `container_capability: none`; the legacy `mode=api` input SHALL resolve to
  the same inline behavior, while legacy `mode=workspace` remains only a
  compatibility shim into the RDR-037 capability model.
  *Tests:* `spec/requests/chat_sessions_spec.rb`,
  `spec/services/chat_sessions/create_spec.rb`.
  *Code:* `ChatSessionsController#create_params`,
  `ChatSessionsController#container_capability_for_legacy_mode`,
  `ChatSessions::Create#call`,
  `ChatSessions::Create#persist_system_message`.

- [x] **CHAT-API-002** — When an API-mode chat turn is sent through JSON, SSE,
  or ActionCable, the system SHALL persist the user/assistant conversation,
  stream start/chunk/tool/completion events, and return a paused status instead
  of an error when the loop stops for a write-tool confirmation.
  *Tests:* `spec/requests/chat_messages_spec.rb`,
  `spec/channels/chat_channel_spec.rb`,
  `spec/jobs/chat_sessions/process_message_job_spec.rb`,
  `spec/services/chat_sessions/send_message_spec.rb`.
  *Code:* `ChatMessagesController#create`,
  `ChatMessagesController#stream_sse_response`,
  `ChatMessagesController#assistant_response_payload`,
  `ChatChannel#send_message`,
  `ChatSessions::ProcessMessageJob#perform`,
  `ChatSessions::SendMessage#call`.

- [x] **CHAT-API-003** — When the API-mode chat loop receives tool calls, the
  system SHALL execute authorized read-only tools inline, advertise write tools
  without model-supplied confirmation, persist pending write-tool confirmation
  messages, and record token usage even for turns that pause before a final
  assistant message is emitted.
  *Tests:* `spec/services/chat_sessions/agent_loop_spec.rb`,
  `spec/mcp/tools/registry_spec.rb`,
  `spec/jobs/chat_sessions/process_message_job_spec.rb`.
  *Code:* `Tools::Registry.chat_definitions_for`,
  `ChatSessions::AgentLoop#run`,
  `ChatSessions::AgentLoop#process_tool_call`,
  `ChatSessions::AgentLoop#process_write_tool_calls`,
  `ChatSessions::AgentLoop#pause_for_confirmation`.

- [x] **CHAT-API-004** — When a pending API-mode write-tool confirmation is
  approved or denied, the system SHALL atomically claim the pending row, inject
  `confirmed: true` only on approval, persist the tool result, and resume the
  loop only after the last pending confirmation has been resolved.
  *Tests:* `spec/requests/chat_messages_spec.rb`,
  `spec/services/chat_sessions/resolve_tool_call_spec.rb`.
  *Code:* `ChatMessagesController#resolve`,
  `ChatMessagesController#stream_resolve_response`,
  `ChatSessions::ResolveToolCall#call`,
  `ChatSessions::ResolveToolCall#claim_resolution!`,
  `ChatSessions::ResolveToolCall#confirmed_arguments`,
  `ChatSessions::ResolveToolCall#resume_loop_unless_other_pending`.

- [x] **CHAT-API-005** — When API-mode chat usage is recorded, the system SHALL
  attribute token usage to the chat session and surface aggregated token and
  cost totals through the chat session APIs so operators can observe chat
  consumption without conflating it with agent-run totals.
  *Tests:* `spec/requests/chat_messages_spec.rb`,
  `spec/requests/chat_sessions_spec.rb`,
  `spec/services/chat_sessions/send_message_spec.rb`.
  *Code:* `TokenUsageTracker.track`,
  `TokenUsageTracker.record_per_request_usage`,
  `ChatSessionsController#session_scope_with_token_totals`,
  `ChatSessionsController#session_json`.

- [x] **CHAT-API-006** — When an API-mode chat runner raises a provider error
  such as a rate limit, the system SHALL retry the turn on a usable API-key
  backed replacement runner, preferring a runner newly selected on the chat
  session and then falling back through chat fallback-enabled runners; inline
  chat runner selectors SHALL only offer runners that can build an API chat
  client.
  *Tests:* `spec/services/chat_sessions/fallback_runners_spec.rb`,
  `spec/jobs/chat_sessions/process_message_job_spec.rb`,
  `spec/requests/chat_sessions_spec.rb`.
  *Code:* `ChatSessions::FallbackLoop#run_with_fallbacks`,
  `ChatSessions::FallbackRunners.for`,
  `ChatSessionsController#load_sidebar_data`.

- [x] **CHAT-API-007** — When a chat client is built for a z.ai direct-provider
  runner (`zai` or `zai_coding`), the system SHALL pass an output-token cap of
  16,384 to the OpenAI-compatible transport so GLM chat responses are not
  truncated into empty content by the transport's lower default; chat clients
  for other OpenAI-compatible providers SHALL keep the transport default.
  *Tests:* `spec/services/chat_sessions/build_llm_client_spec.rb`.
  *Code:* `ChatSessions::BuildLlmClient#openai_compatible_client`,
  `Runner::DIRECT_OUTBOUND_API_PROVIDERS`,
  `ChatSessions::BuildLlmClient::HttpClient#chat_kwargs`.

- [x] **CHAT-API-008** — When rendering the chat session show page
  (`GET /chat/:id` as HTML), the conversation panel's outer wrapper SHALL
  bound its height to the available viewport using `dvh` units (after the
  fixed top nav and the page's `py-8` padding) so the inner
  `overflow-y-auto` region is the actual scroll container rather than the
  document. The wrapper SHALL keep the previous `min-h-[70vh]` floor so
  short content still leaves enough room for the header, message list, and
  input form, and SHALL add a `max-h-[calc(100dvh-...)]` cap so longer
  transcripts bound to the viewport instead of overflowing the page; both
  bounds are required because the chat controller's `scrollToInput`,
  `scrollToTop`, and `handleScroll` (back-to-top visibility +
  auto-scroll tracking) only fire on `containerTarget.scrollTop`, which
  stays at 0 when the document scrolls instead of the intended container
  (#3459, follow-up to #3331).
  *Tests:* `spec/requests/chat_sessions_spec.rb` ("height-bounds the chat
  panel …", "gives the conversation's scroll wrapper a min-h-0 flex
  constraint (#3331)").
  *Code:* `app/views/chat_sessions/show.html.erb` (chat panel outer wrapper).
