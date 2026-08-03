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
