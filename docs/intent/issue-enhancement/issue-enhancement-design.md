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
their core (RDR-052). The enhancement prompt therefore grounds both — today
in the supplied retrieval results and knowledge-base context, and eventually
in the repository itself.

**Current execution capability (pre-Phase 1):** `enhance_issue` runs as a
direct LLM call (`AgentHarness.send_message` with `tools: :none`) inside the
Temporal worker process. The workflow short-circuits `enhance_issue` to the
activity at `agent_execution_workflow.rb:151`, so the run is in the
`skip_clone` set at `agent_execution_workflow.rb:234` and never provisions a
container or clones the repository. The agent's only codebase view is the
retrieval results (`Knowledge::Search`) and knowledge-base context bundle
(`Knowledge::ContextBundle::Build`) attached to the prompt. The prompt
states this constraint explicitly so the agent does not fabricate file paths
or claim a repo read it never made.

**RDR-052 Phase 1 (#3254) — read-only containerized execution.** When that
work lands, `enhance_issue` will route through container provisioning with a
read-only repo mount (`app/services/containers/provision_for_chat.rb` is the
closest analog) and authenticate via the DB-stored runner credential. At that
point the following claims become behavioral rather than aspirational, and
ISSUE-ENHANCEMENT-006 / 007 move from `[D]` to `[x]`:

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

## Containerized, read-only execution (RDR-052)

As of RDR-052 Phase 1, `enhance_issue` runs as a **containerized agent with
repository access** instead of a direct `AgentHarness.send_message` call inside
the worker process. The agent authenticates via the runner-credential injection
path (DB-stored credential → container-injected), removing this step's
dependency on `ANTHROPIC_API_KEY` in the environment.

The run is **read-only**:

- *Structural* — the workspace bind mount uses `:ro` (state/scratch volumes
  under `/home/agent/` remain writable). See
  `app/services/containers/provision.rb#workspace_mount_mode`.
- *Behavioral* — the agent prompt states the workspace is read-only so the
  agent does not attempt writes that would fail.

The run uses the default shallow clone (`--depth 1`), which is sufficient for
codebase exploration during enhancement. The existing `<!-- paid:enhance-issue -->`
marker, needs-input / clarifying-questions flow, and re-evaluation loop are
unchanged.

After the agent finishes exploring the repo and producing structured output,
`EnhanceIssueActivity` (post-run mode) reads the agent's JSON output from the
run logs, builds the comment with the marker, posts it via the GitHub client,
and applies label state — preserving the existing output contract.
