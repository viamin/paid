---
parent: PAID
prefix: CHAT-SESSION-PREFERENCES
---

# Low-Level Design: Chat Session Preferences

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers lightweight preference updates made from the chat UI while a
> conversation is in progress.

## Purpose

Chat session controls such as the auto-approve toggle live beside the message
composer. Updating those preferences must not discard in-progress user input or
conversation state. The UI therefore updates preference state in place rather
than navigating away from the current conversation.

## Auto-approve toggle

The auto-approve checkbox in the conversation view submits through Turbo
Streams. `ChatSessionsController#update` persists the new preference and
returns an empty Turbo Stream response so Turbo completes the request without a
redirect or full-page reload. JSON callers keep the existing JSON response and
non-Turbo HTML callers keep the redirect flow.

## Runner and model controls

The session configuration UI presents one runner-and-model selection rather
than independent runner and model fields. It offers only the curated Low,
Medium, and High choices that are compatible with each chat-capable,
non-free-policy runner; the label includes both the user-facing tier and the
concrete model ID. A free-policy runner offers no saved model choice because
the eligible free pool dynamically selects its model on every request. Low is
the default for a new session. The selector is deliberately not a catalog
browser: catalog refreshes may replace a compatible concrete model within its
existing tier but cannot add choices or promote a chat to a more expensive
tier. API-key availability evidence, operator disables, and agent-harness
compatibility filter these choices. An unavailable tier has actionable
feedback rather than silently selecting a higher tier.
Project provider restrictions, model allowlists and exclusions, and tier
limits filter the choices for linked project context through the same policy
path used by agent runs.

The new-chat dialog applies the same filtering for the project selected inside
the dialog. The runner-and-model choices are rendered unfiltered while no
project is chosen; when the user picks or changes the project, the dialog
re-fetches the curated choices from `ChatSessionsController#runner_model_options`
for that project and rebuilds the selector, resetting any selection the new
policy no longer permits. The create path resolves the submitted option against
the same policy projects, so the offered choices and the accepted choices
cannot drift apart. A failed or stale refresh never widens what the server
accepts: resolution on create remains the authority.

The submitted option is resolved against the current user's available chat
runners before it is saved, so a stale or crafted selection cannot pair a
runner with an unrelated model. Legacy Automatic sessions (`model: nil`)
resolve to Low on their next execution and record that effective choice;
explicit stored models are preserved.

Changing the selection in either chat header saves through Turbo. A status
beside the control shows when saving is in progress and whether it succeeded
or failed. The conversation stays in place, and the control remains editable
after a failed save. If an existing session has a pair that is no longer
configured, no invalid option is rendered; the user is prompted to choose a
valid replacement.
