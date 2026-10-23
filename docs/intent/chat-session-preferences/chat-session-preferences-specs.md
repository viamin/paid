# EARS Specs: Chat Session Preferences

> Testable claims for updating lightweight chat-session settings from the live
> conversation UI. Status markers: `[x]` implemented, `[ ]` active gap,
> `[D]` deferred. Each ID is a grep target across specs, tests, and code.

## Auto-approve

- [x] **CHAT-SESSION-PREFERENCES-001** - When a user toggles the
  auto-approve checkbox from an active chat conversation, the system SHALL
  persist the new `auto_approve` value and complete the update in place
  without a redirect or full-page reload, so unsent message input remains in
  the DOM.
  *Tests:* `spec/requests/chat_sessions_spec.rb`
  ("updates the auto-approve flag in place for Turbo Stream requests").
  *Code:* `app/views/chat_sessions/_conversation.html.erb`,
  `ChatSessionsController#update`.

## Runner and model selection

- [x] **CHAT-SESSION-PREFERENCES-002** - When a user chooses a runner and
  model combination in the chat header, the UI SHALL save the changed
  selection automatically and show whether the update succeeded, without
  navigating away from the conversation.
  *Test:* `spec/requests/chat_sessions_spec.rb`.
  *Code:* `app/views/chat_sessions/_chat_panel.html.erb`,
  `app/javascript/controllers/chat_controller.js`.

- [x] **CHAT-SESSION-PREFERENCES-003** - When a user configures a chat session,
  the system SHALL present only one compatible, tool-capable curated choice per
  Low, Medium, and High tier for each available non-free-policy runner, with a
  label
  containing the tier and concrete model ID, and SHALL reject selections that
  do not belong to an available runner's curated choices. Free-policy runners
  SHALL not offer a saved curated model choice because their model is selected
  dynamically from the eligible free pool on each request. Low SHALL be the
  default for new chats; legacy Automatic sessions SHALL resolve to Low on
  execution while explicit stored selections remain unchanged. The choices and
  defaults SHALL satisfy operator controls and every linked project's provider,
  model, and tier policies. The new-chat dialog SHALL offer only the choices
  permitted for the project selected in the dialog, re-resolving them whenever
  that selection changes, so an offered choice is never rejected by the
  selected project's policy at create time.
  *Tests:* `spec/services/chat_sessions/runner_model_options_spec.rb`,
  `spec/services/chat_sessions/create_spec.rb`,
  `spec/services/chat_sessions/build_llm_client_spec.rb`,
  `spec/requests/chat_sessions_spec.rb` ("GET /chat/runner_model_options").
  *Code:* `ChatSessions::RunnerModelOptions`,
  `ChatSessions::CuratedModelOptions`, `ChatSessionsController`,
  `app/views/chat_sessions/_session_details.html.erb`,
  `app/views/chat_sessions/_new_session_modal.html.erb`,
  `app/javascript/controllers/chat_runner_model_options_controller.js`.

## Thinking effort

- [D] **CHAT-THINKING-EFFORT-001** - When an API-key chat's effective model
  and agent-harness transport both declare configurable reasoning, the system
  SHALL offer only the normalized effort values supplied by that capability;
  it SHALL offer no thinking control otherwise. The provider/model default
  SHALL be an explicit choice that sends no effort parameter and SHALL NOT
  mean maximum effort.
  *Tests:* `spec/services/chat_sessions/thinking_effort_spec.rb`,
  `spec/models/llm_model_spec.rb`.
  *Code:* `LlmModel#reasoning_effort_values`, `ChatSessions::ThinkingEffort`.

- [D] **CHAT-THINKING-EFFORT-002** - When configurable reasoning is supported,
  the chat configuration SHALL distinguish the model tier from thinking
  effort, persist the selected session preference, and display its effective
  value where session configuration is inspected. It SHALL NOT expose
  chain-of-thought.
  *Tests:* `spec/requests/chat_sessions_spec.rb`.
  *Code:* `app/views/chat_sessions/_session_details.html.erb`,
  `ChatSessionsController#session_json`.

- [D] **CHAT-THINKING-EFFORT-003** - When a user switches model tier or runner,
  or when a fallback changes the effective model, the system SHALL revalidate
  the stored preference and visibly clear an incompatible value to Default.
  *Tests:* `spec/requests/chat_sessions_spec.rb`,
  `spec/services/chat_sessions/fallback_runners_spec.rb`.
  *Code:* `ChatSessionsController`, `ChatSessions::FallbackRunners`.

- [D] **CHAT-THINKING-EFFORT-004** - When a selected thinking effort is
  supported by the effective model and chat transport, the system SHALL pass
  its normalized value through agent-harness for streaming and non-streaming
  turns and record the effective setting with attempt metadata. It SHALL never
  send a parameter unsupported by the provider protocol.
  *Tests:* `spec/services/chat_sessions/build_llm_client_spec.rb`,
  `spec/services/chat_sessions/record_transport_attempt_spec.rb`.
  *Code:* `ChatSessions::BuildLlmClient::HttpClient`,
  `ChatSessions::RecordTransportAttempt`.

- [D] **CHAT-THINKING-EFFORT-005** - When the effective model changes through
  a tier/model/runner update or fallback, the system SHALL normalize a stored
  thinking preference to Default when the new capability does not permit it.
  *Tests:* `spec/services/chat_sessions/fallback_runners_spec.rb`.
  *Code:* `ChatSessionsController`, `ChatSessions::FallbackRunners`,
  `ChatSessions::BuildLlmClient`.

- [D] **CHAT-THINKING-EFFORT-006** - When a client directly submits a
  thinking-effort value, the system SHALL accept only a value allowed for the
  request's effective model and transport, and SHALL reject a stale or crafted
  unsupported value.
  *Tests:* `spec/services/chat_sessions/thinking_effort_spec.rb`.
  *Code:* `ChatSessionsController#resolve_thinking_effort!`,
  `ChatSessions::ThinkingEffort#resolve!`.

- [D] **CHAT-THINKING-EFFORT-007** - Before an API-mode chat request is built,
  the system SHALL normalize the persisted preference against the effective
  model and omit it when unsupported, including models selected dynamically
  from a free-model pool.
  *Tests:* `spec/services/chat_sessions/thinking_effort_spec.rb`.
  *Code:* `ChatSessions::ThinkingEffort`, `ChatSessions::BuildLlmClient`.

- [D] **CHAT-THINKING-EFFORT-008** - When agent-harness accepts a normalized
  thinking effort, the transport candidate and corresponding attempt record
  SHALL carry that effective value for both streaming and non-streaming turns;
  when it does not accept the value, neither shall carry it.
  *Tests:* `spec/services/chat_sessions/build_llm_client_spec.rb`.
  *Code:* `ChatSessions::BuildLlmClient::HttpClient`,
  `ChatSessions::RecordTransportAttempt`.

All CHAT-THINKING-EFFORT claims are deferred pending an explicit
viamin/agent-harness ChatTransport capability/request dependency. Paid's
fail-closed gate keeps the selector hidden and omits the parameter until that
contract is installable and verified. The pinned 0.44.22 is the newest
published release, so no pin update can exercise the contract yet; the
tracking issue stays open until a contract-carrying release is pinned and
verified — this scaffolding alone does not deliver the capability.
