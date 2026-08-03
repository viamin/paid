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
