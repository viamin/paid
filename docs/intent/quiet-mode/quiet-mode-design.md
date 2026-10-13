---
parent: root
prefix: QUIET-MODE
---

# Quiet mode design

Projects may opt into a quiet GitHub timeline without losing Paid's durable
workflow state. Quiet mode is a project-scoped boolean, disabled by default.
When enabled it suppresses issue and pull-request comments at the GitHub client,
automation-provider, and issue-tracker adapter boundaries. It does not suppress
PR body creation or updates, labels, review submissions, run state, or inbox
state.

The project-scoped GitHub client decorator is required because a token-backed
`GithubClient` can be shared by more than one project. It intercepts comment
creation and pull-request comment replies without changing the rest of the
GitHub client surface. Provider and tracker boundaries also short-circuit so
future implementations cannot bypass the preference accidentally.

Permission-blocker commentary is the exception that receives a replacement:
when auto-merge lacks the required App permission, quiet mode publishes one
blocking `action_required` notification for the project instead of a GitHub
comment. Escalations remain load-bearing through labels and PR phase state.

Clarifying-question answers currently persist only in a marker-tagged GitHub
comment. In quiet mode, the channel moves into a marked section of the issue
or PR description: questions are written between `<!-- paid:clarifying-questions -->`
and `<!-- /paid:clarifying-questions -->` markers, and answers between
`<!-- paid:clarifying-answers -->` and `<!-- /paid -->` markers, with a
stable question-set digest embedded in both sections so `Load` can match
them without relying on `comment.created_at`. Body editing is the permitted
channel in quiet mode, and a single shared `ClarifyingQuestions::SubmitAnswers`
service writes through that channel for both the inbox controller and the
linked-chat MCP tool so per-call-site branching stays out of the request path.

## Commit-message commentary channel (#4232)

When quiet mode disables the per-push summary comment that
`Activities::CompleteExistingPrunActivity` normally posts after a successful
push to an existing PR, the agent's narrative does not disappear — it is
rerouted into the commit messages the agent already writes for every push.
The agent-facing prompt is the contract for that rerouting:

- `Prompts::BuildForPr` injects a `commit_message_guidance` variable into the
  PR follow-up prompt when quiet mode is on, with a separate Section
  (`quiet_mode_commit_message`) in the PromptAssembly path. The guidance
  tells the agent that no summary comment will be posted and that every
  commit on the branch must carry a reviewer-facing subject and body. The
  legacy builder appends that Section when a custom or pinned prompt version
  omits the `commit_message_guidance` interpolation, so customization cannot
  remove the contract.
- `PromptAssembly::Sections::IssueTask` appends the same guidance as a
  required assembly section after rendering the issue template (and the legacy
  `Prompts::BuildForIssue` fallback injects it for its path), so project
  overrides and pinned prompt versions cannot omit the contract for initial
  implementation commits.

`Activities::CompleteExistingPrunActivity` short-circuits both the
`summary_comments_enabled?` and `add_comment` paths as soon as quiet mode is
detected, so neither the LLM summary generation nor the comment API call
runs in quiet mode. Comment generation is omitted alongside the post so the
suppression does not pay for tokens it cannot emit.
