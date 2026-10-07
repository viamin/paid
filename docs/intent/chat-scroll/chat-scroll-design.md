---
parent: PAID
prefix: CHAT-SCROLL
---

# Low-Level Design: Chat Transcript Navigation

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment defines client-side navigation within the interactive chat transcript.

## Purpose

Long transcripts need predictable shortcuts to the current conversation
context. The chat controller keeps the transcript's own overflow container as
the scrolling surface and offers controls that land at the top of the latest
assistant text response rather than after it, where tool cards or the composer
could hide the answer's opening.

## Navigation behavior

The top-bar and sticky controls share one target: the top of the last rendered
assistant text response, measured relative to the transcript container. Tool
cards do not become response anchors. If no assistant text exists, such as a
new or user-only conversation, the shared target is the bottom of the
transcript.

On a forward page visit, the controller applies that target immediately so the
latest answer starts in view. It does not override browser or Turbo restoration
visits, which retain the user's remembered transcript position. Because a
direct `scrollTop` assignment does not emit a scroll event, the controller
recomputes its scroll controls after the on-load jump so their visibility
matches the final position.
