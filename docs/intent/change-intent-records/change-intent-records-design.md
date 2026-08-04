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

This segment replaces the stale RDR statement that the capability is entirely
unimplemented.

## Shipped Behavior

The current primary creation path is a chat session scoped to a project. The
agent can draft a Change Intent Record, the human approves or denies it, and an
approved record is activated and synchronized into the knowledge artifact
pipeline.

Retrieval is also live: change intents appear as a distinct section in context
bundles and are available through MCP read tools for later agent turns.

## Active Gap

The missing work is around broader capture surfaces, not the core record
mechanics:

- issue-enhancement flows do not yet offer or create Change Intent Records from
  issue constraints
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
