---
parent: PAID
prefix: CHANGE-INTENT
---

# Low-Level Design: Change Intent Records

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the shipped Change Intent Record lifecycle for chat-driven
> directional intent and the remaining intake gaps outside that chat path.

## Purpose

RDR-042 identified the need for a durable artifact that captures human
directional intent such as rejected alternatives or non-obvious constraints.
The repository now ships the core model and knowledge-path implementation:

- `ChangeIntent` as a first-class model with draft/active/superseded lifecycle
- the `record_change_intent` chat tool with post-dispatch confirmation
- activation that indexes the approved record into the knowledge base
- context-bundle retrieval that shows recent Change Intent Records after
  stronger decision artifacts
- the `change_intent_draft` Inbox lane (#4136) so draft and
  `requested_changes` records are surfaced for human approval, change
  requests, or follow-up chat, with the nav badge cache invalidating on
  every transition into or out of the lane

This segment replaces the stale RDR statement that the capability is entirely
unimplemented.

## Shipped Behavior

The current primary creation path is a chat session scoped to a project. The
agent can draft a Change Intent Record, the human approves or denies it, and an
approved record is activated and synchronized into the knowledge artifact
pipeline.

Retrieval is also live: change intents appear as a distinct section in context
bundles and are available through MCP read tools for later agent turns.

Issue enhancement is now a second capture surface. `EnhanceIssueActivity`
asks the enhancement model to evaluate whether an issue contains a non-obvious
constraint or a rejected reasonable alternative worth preserving. When it does,
the flow drafts an issue-linked `ChangeIntent` (in `draft` status) via
`ChangeIntents::DraftFromIssue`, surfaces the proposal in the enhancement
comment with a review link, and never indexes it until a human approves it
through the `Projects::ChangeIntentsController` review path.

## Inbox lane

Draft CIRs now surface in the Operator Inbox as a `change_intent_draft` lane
(#4136) so the operator has a single, discoverable surface for review. The
lane derives directly from `ChangeIntent.pending_review`, reuses the existing
`ChangeIntentPolicy::Scope` for visibility (rather than the auto-pick gate
other issue lanes use), and offers three actions from the detail pane:

- **Approve** — calls `Projects::ChangeIntentsController#approve`, which
  invokes `ChangeIntents::Activate` and indexes the record into the knowledge
  pipeline. The entry clears from the queue on the next render.
- **Request changes** — calls `#request_changes`, which stamps the operator
  reason and timestamp via `ChangeIntents::RequestChanges` and transitions the
  draft into `requested_changes`. The entry stays in the Inbox with the
  reason visible until a follow-up chat or MCP revision overwrites the draft
  and the operator re-approves.
- **Chat about this** — POSTs to the existing `inbox_interactive_chat_path`,
  opening the canonical interactive chat session for the entry so the
  operator can discuss the draft and revise it through conversation. Edits
  update the draft in place (the model only allows status, supersedes, and
  the requested_changes metadata to mutate; title/intent/etc. are written by
  re-recording the change intent).

Approve, request-changes, and discard actions all honour a `return_to`
parameter scoped to `/inbox…` and fall back to the pre-inbox project page
otherwise, so the bell/notification surface is never invoked from this lane.
The nav badge cache (`Inbox::Count`) is invalidated on every transition into
or out of the lane via `ChangeIntent`'s
`after_commit :bump_inbox_cache_version` callback.

## Active Gap

The remaining work is around broader capture surfaces and heuristics, not the
core record mechanics:

- the system does not yet automatically suggest a CIR-worthy capture path at
  every intent-rich touchpoint
- broader policy around which directions deserve capture still relies on prompt
  guidance rather than deterministic product affordances

## What this is not

- **Not a replacement for `DecisionRecord`.** Change intents capture human
  direction, not post-run implementation decisions.
- **Not an always-on transcript mirror.** Records are intended for durable,
  non-obvious constraints and rejected alternatives.
- **Not an unreviewed write path.** Drafts remain human-confirmed before they
  become active knowledge.
- **Not a notification surface.** Draft CIRs appear in the Inbox (which is
  the home for actionable items), never in the bell/notification surface,
  which stays reserved for blocking notifications and account events.
