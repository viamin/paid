---
parent: PAID
prefix: ISSUE-ENHANCEMENT
---

# Low-Level Design: Issue Enhancement

> Companion to the high-level design (`docs/high-level-design.md`). This is the
> LLD for the `enhance_issue` goal — the synchronous human-in-the-loop step
> that decides whether an issue is implementation-ready or needs targeted human
> answers before `create_pr` runs.

## Purpose

Before a project spends a full implementation run on an underspecified issue,
Paid can enhance the issue in place. The enhancement step either:

- posts concise implementation context grounded in the repo and knowledge base, or
- posts clarifying questions through the existing `needs_input` flow and waits
  for a human answer on the issue.

This design keeps enhancement as a layer on top of normal implementation: the
same issue can still proceed without enhancement, and enhancement does not
introduce a new issue state or a parallel UI surface.

## Universal question style

When the issue is not ready, enhancement asks questions in plain language with
no LID-specific jargon. The questions should narrow the change along six axes:

1. the problem being solved,
2. the desired behavior, preferably in a "when X, the system should Y" form,
3. constraints,
4. alternatives considered or rejected,
5. in-scope versus out-of-scope work,
6. how a human will know the work is done.

The activity still emits the same markdown shape:

- `## Clarifying questions`
- numbered questions
- `## Current context`

That preserves the existing parser, `paid_state: "needs_input"` handling,
dashboard queue, answer form, and answer-ingestion flow.

## Codebase-grounded questions and sufficiency

Question-generation and answer-sufficiency judgment are codebase questions at
their core (RDR-052). The enhancement prompt therefore grounds both in the
actual repository rather than knowledge-base snapshots alone:

- **Self-answer what the code determines.** The agent explores the repository,
  retrieval results, and knowledge-base context to answer for itself the things
  the code already says — existing models/types, platform targets, persistence
  format, current architecture and patterns. It SHALL NOT ask the human
  clarifying questions whose answers are directly readable from the repository
  (ISSUE-ENHANCEMENT-006 / RDR R3); it asks only about genuine product, scope,
  or intent ambiguities the code cannot resolve.
- **Grounded sufficiency verdict.** On re-evaluation, the agent judges readiness
  against the user's answers TOGETHER WITH the actual codebase it reads, not
  the knowledge-base snapshot alone (ISSUE-ENHANCEMENT-007 / RDR R4). This
  keeps the readiness gatekeeper at least as informed as the `create_pr` run it
  authorizes.
- **Grounded implementation context.** When the issue is ready, the posted
  implementation context cites real files, symbols, and patterns read from the
  repository, not inferred-from-snapshot guesses.

The workspace is read-only: the agent may explore the repository to ground its
questions and verdict but cannot modify files, commit, or push (RDR R2). Its
only outputs remain the posted comment and label state.

## Re-evaluation comment admission

When the user answers, the `needs_input` label is cleared and a re-evaluation
run is queued (see `fetch_issues_activity#detect_enhance_issue_rechecks`). The
re-evaluation LLM must see the prior clarifying questions and answers to decide
whether the issue is now actionable.

Both the questions and the captured-answers comments are posted by the
project's GitHub App bot (`paid-agents[bot]`). The human-only comment trust
filter (`Project#trusted_github_user?`) deliberately excludes the bot — Paid
must not feed arbitrary bot comments back into the agent as an untrusted input
channel. The re-evaluation therefore re-admits only Paid's own structured
marker comments (`<!-- paid:enhance-issue -->`, `<!-- paid:clarifying-answers -->`)
via `ClarifyingQuestions::CommentAdmission`, backed by the unspoofable
`Project#paid_bot_author?` check. This is scoped: it never broadens the comment
trust used for arbitrary conversation, so a spoofed marker in an attacker's
comment is still rejected.

## LID-aware materialization

For non-LID projects, answered clarifying questions only provide better human
intent for the implementation prompt.

For LID-configured projects, the same captured answers are surfaced forward to
`Prompts::BuildForIssue` as explicit elicited intent. The implementation run
then carries those human answers into the repo's LID process, where the agent
must draft or update the relevant LLD and EARS artifacts before or alongside
the code changes that implement them.

The enhancement flow itself does not create LID artifacts. It captures and
surfaces intent; the later `create_pr` run materializes that intent when the
project's LID mode says it should.
