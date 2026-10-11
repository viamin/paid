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
  the system SHALL present a single choice for each valid runner/model pair,
  including an Automatic choice for every available runner, and SHALL reject
  selections that do not belong to an available runner's configured models.
  *Test:* `spec/requests/chat_sessions_spec.rb`.
  *Code:* `ChatSessions::RunnerModelOptions`,
  `ChatSessionsController`, `app/views/chat_sessions/_session_details.html.erb`.
