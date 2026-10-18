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
