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

**RDR-052 Phase 1 (#3254) — comment-only containerized execution.** Phase 1
routes `enhance_issue` through container provisioning (with the workspace
mounted writable so the platform can clone the repo before the agent starts)
and authenticates via the DB-stored runner credential. The run itself is
comment-only at the workflow level — `RunAgentActivity` skips git
post-processing and `workspace_mount_mode` is `:rw` so clone can populate
`/workspace` — and the agent prompt instructs the agent accordingly. This
moved ISSUE-ENHANCEMENT-006 from `[D]` to `[x]` (containerized execution and
credential unification, RDR R1/R2).

**RDR-052 Phase 2 (#3255) — codebase-grounded questions and re-evaluation.**
Building on Phase 1's repository access, Phase 2 changed the `enhance_issue`
prompt and re-evaluation flow to actually ground question-generation and the
sufficiency verdict in the cloned repository rather than only the
knowledge-base snapshot. This moved the following claims from aspirational to
behavioral, and ISSUE-ENHANCEMENT-008 / 009 from `[D]` to `[x]`:

- **Self-answer what the code determines.** The agent explores the repository,
  retrieval results, and knowledge-base context to answer for itself the things
  the code already says — existing models/types, platform targets, persistence
  format, current architecture and patterns. It SHALL NOT ask the human
  clarifying questions whose answers are directly readable from the repository
  (ISSUE-ENHANCEMENT-008 / RDR R3); it asks only about genuine product, scope,
  or intent ambiguities the code cannot resolve.
- **Grounded sufficiency verdict.** On re-evaluation, the agent judges readiness
  against the user's answers TOGETHER WITH the actual codebase it reads, not
  the knowledge-base snapshot alone (ISSUE-ENHANCEMENT-009 / RDR R4). This
  keeps the readiness gatekeeper at least as informed as the `create_pr` run it
  authorizes.
- **Grounded implementation context.** When the issue is ready, the posted
  implementation context cites real files, symbols, and patterns read from the
  repository, not inferred-from-snapshot guesses.

The workspace is mounted writable so the platform can clone the repo into
`/workspace` before the agent runs, but the run is **comment-only**: the
workflow discards any workspace modifications, never commits, never pushes,
and never opens a PR (RDR R2). The agent may explore the repository to ground
its questions and verdict, but its only durable outputs are the posted comment
and label state. The agent prompt must instruct the agent that the run is
comment-only so it does not attempt writes that would be discarded anyway.

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

## Containerized, comment-only execution (RDR-052)

As of RDR-052 Phase 1, `enhance_issue` runs as a **containerized agent with
repository access** instead of a direct `AgentHarness.send_message` call inside
the worker process. The agent authenticates via the runner-credential injection
path (DB-stored credential → container-injected), removing this step's
dependency on `ANTHROPIC_API_KEY` in the environment.

The run is **comment-only**:

- *Structural* — the workspace bind mount is `:rw` (state/scratch volumes
  under `/home/agent/` are also writable). The platform populates `/workspace`
  via the normal clone path before the agent starts; the workflow skips git
  post-processing for `enhance_issue` so any agent writes are discarded. See
  `app/services/containers/provision.rb#workspace_mount_mode` and
  `app/temporal/activities/run_agent_activity.rb`.
- *Behavioral* — the agent prompt instructs the agent that the run is
  comment-only so it does not attempt writes that would be discarded anyway.

The run uses the default shallow clone (`--depth 1`), which is sufficient for
codebase exploration during enhancement. The existing `<!-- paid:enhance-issue -->`
marker, needs-input / clarifying-questions flow, and re-evaluation loop are
unchanged.

After the agent finishes exploring the repo and producing structured output,
`EnhanceIssueActivity` (post-run mode) reads the agent's JSON output from the
run logs, builds the comment with the marker, posts it via the GitHub client,
and applies label state — preserving the existing output contract.

Structured runners (OpenCode, Codex) capture the transcript as JSONL: one
`agent_message`-shaped event per physical line, with the delimiter's newlines
escaped inside a JSON string field. A blind regex match against the raw
stdout can never find the delimiter there, and a runner's own turn-selection
heuristics can select an earlier progress message instead of the true final
one — both observed in production (#3786, run 5177 on `viamin/yupyup#9`),
where a produced, correctly delimited answer was discarded and the issue
parked in `manual_review`. `EnhanceIssueActivity#delimited_payload` decodes
every transcript event's own message text and keeps the last delimiter match
found, rather than trusting the runner's own "final message" selection or a
provider-specific parser. This is deliberately narrower than fixing the
runner's turn-selection logic (which belongs in `agent-harness`, not Paid):
Paid only needs to find its own delimiter, not reconstruct general turn
semantics. When extraction still fails despite a delimited payload being
present in the raw output, the run fails non-retryably into `manual_review`
as before, but the enhancement round consumed at queue time is refunded —
a Paid-side extraction defect should not spend round budget meant to bound
repeated *automatic* re-evaluation (ISSUE-ENHANCEMENT-011).

The container agent does not post the enhancement comment itself. Its GitHub
proxy authorization is read-only, and its only durable result is the delimited
structured payload consumed by `EnhanceIssueActivity`. Keeping the external
write after validation prevents a run from both producing a GitHub side effect
and failing as though no useful result existed. The prompt explains this
contract, while the proxy enforces it mechanically.

Read-only access does not imply that every GitHub body is safe prompt input.
The base issue prompt includes comments admitted by Paid's trusted-user filter;
the enhancement run's proxy restricts reads to the associated issue-detail
endpoint. An untrusted comment or unrelated issue body therefore cannot bypass
that filter by instructing the container agent to fetch it. The agent may still
fetch the trusted issue creator's issue description and inspect the repository.

## Prompt deployment

The global `goal.enhance_issue` prompt is runtime configuration required by the
enhancement parser. A source-controlled prompt contract is incomplete until the
corresponding global `PromptVersion` is active in an existing deployment.

Changes to this required prompt ship through an idempotent data migration that
creates and promotes the expected immutable prompt version under system tenant
access. The seed remains the canonical definition for new databases, while the
migration advances populated databases during normal `db:migrate` deployment.
The code fallback and seeded/migrated template carry the same structured-output
contract.

## Failure containment and attempt limits

Every automatic `enhance_issue` execution counts as an enhancement round when
it is queued, regardless of whether it originated from initial analysis or from
a human-answer re-evaluation. Counting only needs-input label removal events
allows analysis-created follow-ups to bypass the configured limit.

When an enhancement run cannot produce valid structured output, Paid fails the
run non-retryably and parks the issue in the distinct `manual_review` state.
This state transition is the terminal owner of the issue state for that
failure; generic workflow failure handling must not overwrite it with the
auto-pick-eligible `failed` state. Manual-review issues are not treated as
answerable questionnaires and are not repaired by the questionless
`needs_input` cleanup path. Automation resumes only through an explicit
operator-triggered run.
Moving into manual review also clears stored clarification questions and removes
the needs-input label. This keeps the Paid state, GitHub label, and operator UI
from simultaneously claiming that the issue awaits an answer and a manual
review.

When the configured enhancement-round limit has already been reached, Paid
does not queue another enhancement run. It moves the issue to `manual_review`
and posts at most one marked stop comment. Repeated poll or queue ticks are
idempotent and do not create additional stop comments. The containment service
uses a short row-locked state transition to elect one notifier, then performs
GitHub I/O after releasing the database lock. Concurrent queue or poll workers
therefore cannot both publish a stop notice, and a slow GitHub request does not
hold an issue row lock.

## Decisions and alternatives

| Decision | Rationale | Alternatives considered |
|---|---|---|
| Advance required global prompt contracts with idempotent data migrations. | Existing deployments run migrations during setup, while seeds are normally applied only when a database is created. Immutable prompt versions preserve lineage. | Running all seeds on every deploy risks unrelated mutable seed changes; relying on operator-run seeds permits code/runtime contract drift. |
| Let `EnhanceIssueActivity` own GitHub comment creation after payload validation and deny mutation through the enhancement run's proxy authorization. | The platform can make the external side effect consistent with the run result and attach the required marker; enforcement does not depend on prompt compliance. | Direct agent posting occurs before validation and cannot be rolled back when parsing fails. |
| Park malformed or round-exhausted enhancement in a distinct `manual_review` state. | Manual intervention is not an answerable questionnaire. A distinct state prevents questionless-needs-input repair from re-arming auto-pick and gives operators an unambiguous lifecycle state. | `needs_input` is reserved for parseable questions and is automatically repaired when questionless; `paused` represents an operator-imposed operational pause rather than an enhancement outcome; `failed` re-enters auto-pick. |
| Count queued automatic enhancement attempts, not only answered-question re-evaluations. | All attempts consume resources and can produce side effects; a cap must cover every entry path. | Counting label removals misses initial-analysis follow-ups and permits an unbounded loop. |

## Open questions and future decisions

- Duplicate comments created before these invariants were enforced require an
  explicit operator cleanup decision; automatic deletion is outside the
  enhancement lifecycle.
