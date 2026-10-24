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
  selects a conversation per `(creator, inbox item)` so a user’s
  exploratory transcript remains private; a future shared-feature conversation
  must be an explicit collaboration model, not an accidental reuse of a
  personal popup. Persist the inbox key, creator, open/close timestamps and an
  audit snapshot of queue metadata. Serialize creation to
  avoid duplicate conversations on simultaneous Inbox opens. Closed conversations
  remain resumable after inactivity; Inbox opens reuse the active conversation
  or resume the most recently updated closed conversation. Only archived
  conversations are excluded from reuse. Messaging and pending confirmations
  resume the same transcript. Serialize Inbox opens per creator to prevent
  duplicate creation, and select the most recently updated active transcript.
  Resuming an older transcript must not alter another conversation or its
  workspace; multiple historical transcripts may be active concurrently.
  Claim pending confirmations and resume under the session row lock in one
  transaction, checking current archive state before any mutation. Rejected
  or duplicate confirmations must not change session state.
  Closed workspace transcripts remain accessible through Inbox; their workspace
  is restored through the existing explicit workspace-reopen control.
- `ChatSession#clarifying_question_issue` separately links the shipped shared exploration
  flow to its inbox issue or PR. The database permits one non-archived chat
  per linked item; concurrent opens converge on it, and an archived linked
  chat is restored rather than replaced. Its title identifies the linked
  repository and issue or PR number (`Clarifying questions for owner/repo#123`)
  whenever it is created or reopened.
- `ChatSession#feature_intent` links a feature conversation shared by every
  issue attached to that feature. When question exploration is enabled for
  the project, opening an Inbox question on a feature issue reuses the one
  non-archived conversation for that feature (archived conversations are
  restored), adopting a pre-existing per-issue linked chat for a feature
  issue rather than forking context. A standalone issue keeps its own
  per-issue conversation, and issues in unrelated projects never share one.
  Opening another issue records a question focus — it must not repoint the
  conversation's feature or issue linkage. The focus snapshot (issue, pending
  questions, focusing actor, time) lives in session metadata next to the
  questions snapshot, and a focus change appends a system notice carrying the
  newly focused questions so the running transcript stays truthful without
  rebuilding the persisted system prompt.
- Question exploration rolls out through `Project#question_exploration_enabled`,
  initially disabled for every project. The setting gates only the
  feature-conversation path: the legacy per-issue clarifying chat entry stays
  available when it is off. Disabling the setting preserves existing
  conversations, saved answers, evidence, and unrelated run policy — it only
  changes which conversation subsequent opens select. Authorized HTML, API
  (mobile `inbox/entries/:id/chat` and the project settings endpoints) and
  chat-tool (`update_project_settings`) surfaces expose the same toggle with
  the same policy checks.
- Extend `ChatMessage` with actor and question/facet context and typed diagram
  references. Keep domain records for answers separate from transcript text;
  archiving a conversation must not destroy the feature's intent. A
  `ClarifyingQuestionProgress` record identifies a question set digest and
  one-based position, retains the latest confirmed draft answer, actor, time,
  optional canonical design-claim identifier and textual evidence context.
  Saving a draft never posts to GitHub or changes needs-input state; only the
  existing explicit final-submission action performs that projection.
- Reuse the existing chat renderer, Cable/SSE delivery, and agent tool loop.
  When a clarifying-question detail pane opens its linked chat, render the
  existing chat panel inside that Inbox Turbo Frame rather than navigating to
  the full chat page. The frame response retains the panel's definite
  viewport-height contract using the Inbox pane's chrome measurements; the
  full `/chat` route continues to render its sidebar and page shell.
  A shared diagram card handles expansion, accessible textual representation,
  element selection and its own comment composer.
- The chat system prompt carries the linked issue/PR and its pending questions.
  It may ask follow-ups; only the confirmation-gated
  `submit_clarifying_answers` chat tool posts the final ordered answers through
  `ClarifyingQuestions::SubmitAnswers`. That existing path adjusts labels and
  clears the inbox item only after GitHub accepts the comment.
- Chat answers are assistant-composed, not widget-composed, so the choice
  validator accepts any selection spelling that unambiguously picks an offered
  option (canonical line or rendered echo with optional marker prefix and
  appended rationale, bare label, 1-based number, or letter), and the system
  prompt renders choice questions with their canonical option lines plus the
  accepted answer forms. The offered-option invariant of the OPERATOR-INBOX-012
  tamper guard and single/multi selection counting are unchanged.
- Persist extracted answer/evidence context for the facet-confidence segment.
  The saved textual context remains after an archive, reconnect, cancellation,
  or removal of temporary visual material; diagram source is not required to
  restore a question's draft answer.
  Update canonical RDR/LLD/EARS through normal design PRs when intent changes.

## Access and transport contract

Feature conversations inherit project membership authorization, narrowed by
account boundaries. Existing account-visible chat policy alone is insufficient
for a project-scoped shared conversation. Authorize transcript loads,
messages, diagrams, subscriptions, investigation tools and preference writes.
Act as the sending collaborator, not automatically as the session creator;
recheck membership for queued side effects. Do not expose a personal chat by
attaching a feature to it. Each UI action has an equivalent structured API/tool
operation with the same policy checks. Attaching a feature never widens
visibility of chats that are not already project-scoped exploration
conversations, and removing a collaborator's project membership removes their
access to the feature conversation on every transport.

The initial backend treats GitHub-comment authority as the write threshold:
only a project user who can manage issue comments may open or use the linked
chat. Authorization is rechecked for HTML, Cable, messages and context queries.
Inbox context is not appended to the system prompt. `Inbox::ChatContext` is a
section-addressable query boundary; callers request the work item, comments,
review comments, labels, queue metadata, relevant agent-run output, or the
current record-backed lane evidence as needed. Record lookup is scoped to the
session project rather than trusting the audit snapshot. Partial-closeout
queries additionally resolve the current closeout status, evidence, recovery
state, and available uncertainty on demand.

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
An experiment investigation executes its prompt through the question's chat
workspace runtime (the agent-harness execution plan inside the session's
isolated container) under a bounded wall clock, and retains the bounded
output, exit status and truncation evidence on the investigation; readiness
of a workspace alone is never reported as experimental evidence, and a
non-zero exit or runtime failure settles as failed while preserving the
partial output. Research investigations report the knowledge-search scope
they actually executed, including an explicit no-match outcome. Each
investigation is a durable, question-scoped record with queued, running,
authorization-required, completed, failed, and cancelled states. Admission
locks the project while comparing active reservations with daily and monthly
hard-stop budgets; a per-run hard stop bounds the individual request. The job
rechecks execution controls before it starts and releases its reservation if a
new control requires additional authorization. Results and terminal failures
remain attached to the question for reconnecting collaborators.
New investigation dispatch is guarded by the project-scoped
`question_exploration` feature flag, which is off until an operator explicitly
enrolls the project. Disabling the flag prevents new dispatch while preserving
the question's existing answers and investigation records.

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
