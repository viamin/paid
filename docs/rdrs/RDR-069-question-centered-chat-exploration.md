# RDR-069: Question-Centered Chat Exploration

## Metadata

- **Date**: 2026-09-22
- **Status**: Partially Implemented (see [2026-10-22 Closeout](#2026-10-22-closeout))
- **Type**: Product experience and chat architecture
- **Priority**: P1
- **Related RDRs**: [RDR-028](RDR-028-interactive-chat.md), [RDR-053](RDR-053-new-feature-creation.md), [RDR-066](RDR-066-feature-intent-approval-lifecycle.md), [RDR-070](RDR-070-facet-confidence-and-clarification.md), [RDR-071](RDR-071-confidence-driven-issue-delivery.md)
- **Intent**: [Question exploration](../intent/question-exploration/question-exploration-design.md)
- **Implementation tree**: [Human-centered Inbox delivery plan](human-centered-inbox-implementation.md)
- **Related Issues**: Epic [#4309](https://github.com/viamin/paid/issues/4309); closeout [#4322](https://github.com/viamin/paid/issues/4322); gaps [#4311](https://github.com/viamin/paid/issues/4311) (shipped), [#4312](https://github.com/viamin/paid/issues/4312) (shipped), [#4313](https://github.com/viamin/paid/issues/4313) (shipped), [#4316](https://github.com/viamin/paid/issues/4316) (shipped), [#4317](https://github.com/viamin/paid/issues/4317) (closed without shipping the investigation surface), [#4568](https://github.com/viamin/paid/issues/4568) (open — the remaining gap)

## Problem Statement

Paid asks people to resolve product questions, but answering can require more
than reading an issue and filling in a form. A person may need to inspect a
workflow, compare alternatives, ask for research, or try an experiment. The
interface should help them determine an answer rather than require that they
already understand the question.

The valuable output is the resulting understanding and intent. A diagram is
useful insofar as it helps reach that output; preserving every exploratory
drawing is not a product goal.

## Context and Research

The existing Inbox aggregates typed interventions through `Inbox::Queue`.
Clarifying questions already have surrounding context, but
`ClarifyingQuestions::SubmitAnswers` requires all answers and clears
needs-input after posting them. `ChatSession`, `ChatMessage`, the chat agent
loop, and shared list/detail styling provide the foundation for exploration.
Issue #3877 delivered shared layout work; #3891 delivered question context;
issue #3925 reduced chat-header prominence. Extend these rather than rebuilding them.

[Maggie Appleton's planning essay](https://maggieappleton.com/planning-agents)
argues for representations that support human understanding and exploration,
including contact with real code and prototypes before implementation choices.
For Paid, this motivates question-specific aids and a conversational workspace.

[Archify](https://github.com/tt-a1i/archify) offers typed diagrams, navigable
relationships, and structural validation.
[Diagram Design](https://github.com/cathrynlavery/diagram-design) emphasizes
choosing an appropriate representation, low visual density, accessibility, and
rendered validation. Adopt these principles; neither skill is a required
runtime dependency, and their standalone HTML output is not trusted app markup.

## Decision

### Inbox entry, chat workspace

An Inbox question opens a persistent feature conversation focused on that
question. Issue-specific discussions belong to the feature conversation;
standalone issues have their own conversation. Preserve selection, partial
answers, and the return path to Inbox. A question can remain open while the
person answers another. Exploration is distinct from answering, and answering
one question does not automatically clear all outstanding needs-input work.

Use the existing chat UI and message transports. A full-page conversation
provides room for exploration; the popup remains a convenient entry. Opening
another issue must not silently repoint the existing feature conversation.
Authorized project collaborators share the discussion with actor attribution.
Personal chats and unrelated projects do not become shared as a side effect.

### Adapt the aid to the relationship

The agent investigates facts it can establish itself. It presents unresolved
decisions with a plain-language explanation and technical detail on demand.
When context makes a useful method apparent, use it. Otherwise ask how the
person wants to investigate. There is no mandatory progression from prose to
diagram to prototype and no fixed questionnaire for every feature.

Useful aids include prose, comparison tables, user flows, architecture and
state diagrams, code traces, and experiments. Only produce a diagram when it
helps answer the question. Users may redirect the method at any time.
Investigations use `agent_harness`, existing container capabilities, and
explicit project budgets/execution policy. Show progress and cancellation for
long work; obtain additional authorization before exceeding those limits.

### Diagrams inside the conversation

Each diagram names its question and appears as a collapsible chat card with
an accessible summary. Each card has a text input for comments. Selecting an
element adds that element as discussion context; the person may inspect,
question, or propose alternatives. Diagram clicks, collapse state, or trial
edits do not imply a preference or strengthen intent certainty.

The diagram is temporary working material. Keep the active representation
available across reconnects and partial work, but do not create a permanent
archive of discarded versions. Once superseded or no longer useful, it may be
removed. Preserve human comments, the question/facet they address, a short
textual description of relevant context, and the resulting answer. A useful
final diagram may accompany the answer; it is not required for an answer to
remain intelligible or for an issue to become ready.

A delayed comment on a replaced diagram must retain its textual context or
ask for clarification; never silently attach it to a different element.
Deleting temporary visuals must not delete human input or decision evidence.

### Rendering boundary

Use a constrained, validated diagram description rendered by Paid-owned
components for the initial slice. Include a text equivalent and keyboard
navigation. Treat agent labels and links as untrusted input. Do not execute
agent-authored scripts or embed raw generated HTML in the application origin.
Reuse preview/container isolation for executable experiments; adding arbitrary
inline application code is not necessary for chat diagram support.

## Alternatives Considered

| Alternative | Decision and rationale |
|---|---|
| Add diagrams beside the existing answer form only | Insufficient for iterative discussion and investigation; chat becomes the workspace. |
| Build a separate canvas application | Adds a second conversation and context model; extend existing chat first. |
| Require diagrams for every question | Representation depends on what the person needs to understand. |
| Keep every diagram revision | The answer and evidence are durable; intermediate geometry is disposable. |
| Import standalone generated HTML directly | Typed rendering supports selection and comments without trusting generated scripts. |

## Rollout Guard

Expose exploration through a project-level rollout setting, initially disabled
for existing projects. The first chat wiring issue owns this setting. Existing
Inbox actions remain available until the exploration path can save and resume
answers correctly. Disabling new exploration preserves conversations, answers,
and evidence; it does not change run eligibility or another feature's policy.

## Implementation and Validation

Implement conversation linkage, diagram cards/comments, and durable answers
as separate issues. Every user action must have an equivalent authorized
API/tool operation; match HTML, Cable, and SSE behavior.

Test Inbox deep links, project access, partial answers, multiple collaborators,
stale comments, disconnect recovery, diagram replacement, mobile/keyboard
interaction, and absence of script execution. Verify an answer remains useful
after deleting its temporary diagram. Measure human effort and successful
resolution, not diagram count or click volume.

## Trade-offs

Persistent conversation context and structured visual messages add contracts
to the existing chat surfaces. Constrained rendering limits arbitrary visual
tools initially, but supports the first question-centered release without a
general-purpose canvas. Disposable diagrams reduce storage and review noise at
the cost of not replaying every exploratory view.

## Implementation Status

As of the 2026-10-12 closeout, the chat-entry/reuse, final-answer submission,
access-control, and Inbox-chat-context foundation this RDR extends are
shipped with passing test evidence. The diagram-card, durable per-question
progress, adaptive-clarification, and bounded-investigation behavior that
make the experience question-centered are not yet shipped. See the
2026-10-12 Closeout section below and
[`audit-report-2026-10-12-rdr-069.md`](audit-report-2026-10-12-rdr-069.md)
for the full criterion-by-criterion evidence.

On 2026-10-19, [#4311](https://github.com/viamin/paid/issues/4311) (P02)
shipped this RDR's project-level exploration rollout setting
(`projects.question_exploration_enabled`, initially disabled for every
project, exposed through the project settings form and the
`update_project_settings` chat tool) plus the feature/standalone-issue
conversation linkage and question focus: an Inbox question on a
feature-linked issue opens the one shared conversation for that feature
(`ChatSession#feature_intent`, with adoption of pre-existing per-issue
chats), standalone issues keep their own conversation, focus moves visibly
without repointing linkage, and disabling the setting preserves existing
conversations, answers, evidence, and unrelated run policy. The linked open
carries matching subject/actor context through HTML and the mobile Inbox
chat API (`QUESTION-EXPLORATION-018`/`019`).

On 2026-10-22, [#4312](https://github.com/viamin/paid/issues/4312),
[#4313](https://github.com/viamin/paid/issues/4313), and
[#4316](https://github.com/viamin/paid/issues/4316) shipped the diagram card,
the durable per-question progress, and the adaptive-clarification and
explicit-preference slices, so the collapsible question-linked card
(`QUESTION-EXPLORATION-003`, `009`, `011`), attributed element comments that
keep their textual context (`004`, `006`), diagram replacement that releases
superseded visual source while preserving human input (`005`), and archived
answers with their evidence (`013`) are all live.

The 2026-10-22 closeout of [#4322](https://github.com/viamin/paid/issues/4322)
found and fixed two real divergences rather than reporting them satisfied:
human diagram comments were persisted but read by nothing, and a saved answer's
evidence context was persisted but never restored. Both now reach the
transcript, the assistant's exploration context, and the reopened conversation.
See the
[2026-10-22 Closeout](#2026-10-22-closeout) section and
[`audit-report-2026-10-22-rdr-069.md`](audit-report-2026-10-22-rdr-069.md).

Bounded investigations — budget and execution-policy enforcement,
authorization before exceeding either, progress, and cancellation
(`QUESTION-EXPLORATION-010`, plus the investigation slice of `012`) remain the
only unimplemented behavior, now owned by
[#4568](https://github.com/viamin/paid/issues/4568).

As of the 2026-10-22 closeout, the diagram-card, durable-progress, and
adaptive-clarification slices also ship: typed collapsible diagram cards with
an accessible summary, keyboard-reachable element selection and a comment
input (`QUESTION-EXPLORATION-003`, `009`, `011`); human diagram comments that
carry their element text, render in the card, and reach both the assistant's
exploration context and the JSON transport (`QUESTION-EXPLORATION-004`,
`006`); released superseded diagram source with preserved human evidence
(`QUESTION-EXPLORATION-005`); and per-question draft answers with their
recorded human evidence, restored on reopen (`QUESTION-EXPLORATION-002`,
`013`). `spec/integration/question_exploration_journey_spec.rb` exercises the
whole journey as one outcome. Bounded investigations — budget and execution
policy enforcement, overage authorization, progress and cancellation — remain
unimplemented under #4317, so this RDR stays **Partially Implemented**.

## 2026-10-22 Closeout

Closeout issue [#4322](https://github.com/viamin/paid/issues/4322) re-audited
every `QUESTION-EXPLORATION-*` claim against shipped code and a live
`bundle exec rspec` run (3043 examples, 0 failures across the chat, diagram,
clarifying-question, Inbox, policy, API, MCP, view, integration and system
suites) rather than against closed-issue history. Result: **Partially
Implemented** — unchanged in status, materially narrower in remaining scope.

Shipped since the 2026-10-12 closeout:

- `QUESTION-EXPLORATION-003`–`006`, `009`, `011` (diagram cards, comments,
  replacement, safe rendering, non-preference interaction) — #4312.
- `QUESTION-EXPLORATION-013` and the durable-progress scope of `002` — #4313.
- `QUESTION-EXPLORATION-008`, `011` (adaptive clarification, explicit
  preferences) — #4316.
- The conversation-open/focus slice of `012` and this RDR's Rollout Guard
  setting — #4311.

Closeout-driven corrections landed with this audit, because the shipped
pieces did not yet add up to the RDR's stated behavior:

- A diagram comment was write-only. Nothing read `ChatDiagramComment` back,
  so a collaborator's question about an element never reached the person who
  reopened the transcript or the assistant it was aimed at. Comments now
  render in the card (`app/views/chat_diagrams/_diagram.html.erb`), travel
  with the shared JSON serializer (`app/services/chat_diagrams/comment_serializer.rb`,
  `app/services/chat_diagrams/serializer.rb`), and are supplied to the
  assistant's exploration section
  (`app/services/chat_sessions/build_system_prompt.rb`).
- The human evidence context recorded with a saved draft answer was stored but
  never restored; reopening now returns it with the answer, so the reasoning
  behind a saved answer survives an archive and a released diagram.
- The diagram card had only browser-driven coverage. A non-JS view spec
  (`spec/views/chat_diagrams/diagram_partial_spec.rb`) now asserts the
  question identity, summary, text equivalent, keyboard selection, comment
  input, and the absence of any script surface.

Design deltas: there is no hard-delete path for a diagram row. Superseding a
diagram releases its visual source (`current: false`, `description: {}`) while
keeping the row and its comments, which satisfies "do not create a permanent
archive of discarded versions" without inventing a destructive path that
would cascade away human input. The browser-driven system spec
(`spec/system/chat_diagrams_spec.rb`) still skips without Chromium; the view
spec is the running evidence for the same markup in this environment.

Rollout guard disposition: **satisfied and still enforced.** The
project-level setting this guard requires shipped with #4311
(`projects.question_exploration_enabled`, disabled by default for every
project, writable only through the authorized settings form and the
`update_project_settings` tool). It gates the feature-conversation entry;
disabling it preserves existing conversations, answers, and evidence and
changes nothing else. Nothing shipped by this closeout bypasses the guard,
and the investigations that remain under #4317 must sit behind the same
setting when they ship.

Still missing, and still owned by an open issue:

- `QUESTION-EXPLORATION-010` and the investigation slice of
  `QUESTION-EXPLORATION-012` (budget and execution-policy enforcement,
  authorization before exceeding either, progress and cancellation for
  long-running work, and the API/tool parity those actions need) —
  [#4317](https://github.com/viamin/paid/issues/4317), open.

No new gap issue was filed: the only unmet criterion already has a focused,
correctly-scoped open owner. Closeout issue #4322 therefore stays open with
`Tracks #4309` language and depends on #4317; only the umbrella's own final
acceptance audit may close #4309.

## 2026-10-22 Closeout

Closeout issue [#4322](https://github.com/viamin/paid/issues/4322) re-audited
every `QUESTION-EXPLORATION-*` EARS claim in
[`question-exploration-specs.md`](../intent/question-exploration/question-exploration-specs.md)
against shipped code and a live `bundle exec rspec` run (3043 examples, 0
failures, 23 pending — all `spec/system` examples skipped because Chromium is
unavailable in that environment) rather than against closed-issue history.
Result: **Partially Implemented**, unchanged in status but with a much smaller
remaining surface than the 2026-10-12 closeout recorded.

Shipped with running evidence: every claim except `010`. Diagram cards name
their question and carry a text equivalent, collapse/expand and keyboard
interaction; comments are attributed, keep the element text they were made
against, and reach the card, the assistant, and the JSON transport; a
replaced diagram releases its visual source without losing comments, answers,
or evidence; an archived conversation returns its answers and their evidence on
reopen; and the project-level rollout setting gates the entry.

Corrections this closeout made rather than accepting at face value:

- Human diagram comments were write-only — persisted by the HTML and API
  endpoints and read by nothing. They now render in the card, share one payload
  across both transports, and appear in the assistant's exploration context.
- A saved answer's recorded evidence context was never restored. It now returns
  with the answer.
- The diagram card had no non-browser coverage; added
  `spec/views/chat_diagrams/diagram_partial_spec.rb`.
- No end-to-end journey evidence existed; added
  `spec/integration/question_exploration_journey_spec.rb`.
- Reading comments back introduced an N+1 across every transcript path and an
  unbounded read in prompt assembly; both are now bounded in SQL.

`#4317` (P08) claimed the investigation scope and closed as completed without
shipping it, so this closeout filed
[#4568](https://github.com/viamin/paid/issues/4568) to re-own
`QUESTION-EXPLORATION-010` and the investigation slice of
`QUESTION-EXPLORATION-012`. That issue carries no auto-pick skip label, and
the closeout now depends on it explicitly.

The Rollout Guard's project-level setting shipped with #4311 and still gates
the entry; nothing in this closeout made guarded behavior default. Closeout
issue #4322 remains open and keeps `Tracks #4309` language; only the umbrella's
own final acceptance audit may close #4309.

## 2026-10-12 Closeout

Closeout issue [#4322](https://github.com/viamin/paid/issues/4322) audited
every `QUESTION-EXPLORATION-*` EARS claim in
[`question-exploration-specs.md`](../intent/question-exploration/question-exploration-specs.md)
against shipped code and a live `bundle exec rspec` run (467 examples, 0
failures) rather than against closed-issue history. Result: **Partially
Implemented**.

Shipped: `QUESTION-EXPLORATION-001`, `002`, `007`, `014`, `015`, `016`, `017`
(conversation reuse/resumption, final-answer submission, access control and
attribution, Inbox-chat audit metadata, frame rendering, choice-answer
parsing, and on-demand Inbox context resolution).

Not shipped, each tracked by an open, correctly-scoped issue under epic
[#4309](https://github.com/viamin/paid/issues/4309):

- `QUESTION-EXPLORATION-003`–`006`, `009`, `011` (diagram cards) — [#4312](https://github.com/viamin/paid/issues/4312)
- `QUESTION-EXPLORATION-013` and the remainder of `002`'s durable-progress scope — [#4313](https://github.com/viamin/paid/issues/4313)
- `QUESTION-EXPLORATION-008`, `011` (adaptive clarification, explicit preferences) — [#4316](https://github.com/viamin/paid/issues/4316)
- `QUESTION-EXPLORATION-008`–`010`, `013` (bounded investigations) — [#4317](https://github.com/viamin/paid/issues/4317)
- The conversation-open/focus slice of `QUESTION-EXPLORATION-012` and the
  project-level exploration rollout setting this RDR's Rollout Guard
  requires — [#4311](https://github.com/viamin/paid/issues/4311), added as
  an explicit dependency of #4322 by this audit (it was not previously
  listed, even though its own acceptance criteria already name this scope).

No new gap issue was filed: every unmet criterion already has a focused,
correctly-scoped open issue. The Rollout Guard's project-level setting
remains unshipped and is not bypassed by anything shipped so far — the
shipped behavior only extends the pre-existing, already-enabled legacy
clarifying-question chat entry point and introduces no new diagram,
investigation, or preference surface. Closeout issue #4322 remains open and
keeps `Tracks #4309` language; only the umbrella's own final acceptance audit
may close #4309.

> 2026-10-19 update: the #4311 items in the list above (the
> conversation-open/focus slice of `QUESTION-EXPLORATION-012` and the
> project-level exploration rollout setting) have since shipped; see
> Implementation Status. The other listed gaps remain open.
