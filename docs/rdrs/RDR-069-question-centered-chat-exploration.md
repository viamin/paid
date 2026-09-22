# RDR-069: Question-Centered Chat Exploration

## Metadata

- **Date**: 2026-09-22
- **Status**: Draft
- **Type**: Product experience and chat architecture
- **Priority**: P1
- **Related RDRs**: [RDR-028](RDR-028-interactive-chat.md), [RDR-053](RDR-053-new-feature-creation.md), [RDR-066](RDR-066-feature-intent-approval-lifecycle.md), [RDR-070](RDR-070-facet-confidence-and-clarification.md), [RDR-071](RDR-071-confidence-driven-issue-delivery.md)
- **Intent**: [Question exploration](../intent/question-exploration/question-exploration-design.md)
- **Implementation tree**: [Human-centered Inbox delivery plan](human-centered-inbox-implementation.md)

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
