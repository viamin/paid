---
parent: PAID
prefix: QUESTION-EXPLORATION
---

# Question Exploration

## Context and scope

[RDR-069](../../rdrs/RDR-069-question-centered-chat-exploration.md) makes chat
the workspace for questions entered through Inbox. This is planned behavior;
the associated EARS claims are gaps. Start with clarifying questions and reuse
the answers in feature review. Other Inbox action kinds retain their existing
actions.

## Components and ownership

- Extend `ChatSession` linkage to an Inbox item. The first backend increment
  uses one active conversation per `(creator, inbox item)` so a user’s
  exploratory transcript remains private; a future shared-feature conversation
  must be an explicit collaboration model, not an accidental reuse of a
  personal popup. Persist the inbox key, creator, open/close timestamps and an
  audit snapshot of queue metadata. Add uniqueness/concurrency protection to
  avoid duplicate conversations on simultaneous Inbox opens.
- Extend `ChatMessage` with actor and question/facet context and typed diagram
  references. Keep domain records for answers separate from transcript text;
  archiving a conversation must not destroy the feature's intent.
- Reuse the existing chat renderer, Cable/SSE delivery, and agent tool loop.
  A shared diagram card handles expansion, accessible textual representation,
  element selection and its own comment composer.
- Bridge `ClarifyingQuestions::Load` and the existing answer submission path
  to durable per-question progress. Do not call `ClearNeedsInput` merely
  because one answer or an exploration comment was saved.
- Persist extracted answer/evidence context for the facet-confidence segment.
  Update canonical RDR/LLD/EARS through normal design PRs when intent changes.

## Access and transport contract

Feature conversations inherit project membership authorization, narrowed by
account boundaries. Existing account-visible chat policy alone is insufficient
for a project-scoped shared conversation. Authorize transcript loads,
messages, diagrams, subscriptions, investigation tools and preference writes.
Act as the sending collaborator, not automatically as the session creator;
recheck membership for queued side effects. Do not expose a personal chat by
attaching a feature to it. Each UI action has an equivalent structured API/tool
operation with the same policy checks.

The initial backend treats GitHub-comment authority as the write threshold:
only a project user who can manage issue comments may open or use the linked
chat. Authorization is rechecked for HTML, Cable, messages and context queries.
Inbox context is not appended to the system prompt. `Inbox::ChatContext` is a
section-addressable query boundary; callers request the work item, comments,
review comments, labels, queue metadata or relevant agent-run output as needed.

## Temporary visual lifecycle

Retain the current diagram while it supports an active question, including
across reconnects. Diagram metadata carries question identity, a short textual
purpose and element descriptions. Replacing it does not require saving old
visual source. Persist comments with enough text context to understand them
after cleanup. Accept a delayed comment only against identifiable context;
otherwise ask the person to clarify. A useful final diagram is optional.

Keep collapse state as presentation state; do not collapse while the person is
editing its comment. Show a clear expand/collapse control, question title and
summary. A click is never evidence of intent. Support keyboard selection and
text-only exploration. Invalid diagram output falls back to an explanation
and allows the conversation to continue.

## Agent behavior and investigations

Use repository context before asking fact questions. Select useful explanation
and investigation methods semantically; ask for method preference only when
context is insufficient. No mandatory visual format or sequence applies.
Project budgets and execution capabilities bound autonomous investigations;
reserve/check budget before dispatch, show progress, and support cancellation.
Interrupted research preserves partial human input. Executable experiments use
existing isolated previews/containers, never the application's HTML origin.

## Decisions and alternatives

| Decision | Rationale | Alternative |
|---|---|---|
| Question-centered chat | Discussion, partial answers and exploration stay together | Separate canvas and form |
| Durable answers, disposable visuals | Understanding is the product output | Version every diagram |
| Typed Paid-owned rendering | Supports safe interaction and consistent transports | Inject generated HTML |
| Explicit shared project context | Collaboration must preserve access and attribution | Reuse global popup context implicitly |

## Verification

Test subject linkage, authorization on every transport, multiple collaborators,
partial progress, unresolved questions, stale comments, invalid visual output,
budget rejection and recovery. Use real-browser tests for geometry, mobile,
keyboard and collapse behavior. Verify intent survives visual cleanup and chat
archive. The implementation plan is in
[the shared issue tree](../../rdrs/human-centered-inbox-implementation.md).
