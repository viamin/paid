---
parent: quiet-mode
prefix: QUIET-MODE
---

# Quiet mode EARS specifications

- [x] **QUIET-MODE-001** — When an operator enables quiet mode for a project,
  the system SHALL persist that project-only setting, expose it in project
  automation settings, and default it to disabled for all projects.
- [x] **QUIET-MODE-002** — While a project's quiet mode is enabled, when Paid
  attempts to create an issue/PR comment or reply through its project-scoped
  GitHub client, the system SHALL not make the comment API request while
  allowing non-comment GitHub operations, including PR body updates, to proceed.
- [x] **QUIET-MODE-003** — While quiet mode is enabled, when automation code
  invokes either GitHub provider's `add_comment`, the provider SHALL not invoke
  the GitHub client.
- [x] **QUIET-MODE-004** — While quiet mode is enabled on a project-scoped
  issue tracker configuration, when an adapter receives `add_comment`, the
  adapter SHALL not invoke its tracker implementation.
- [x] **QUIET-MODE-005** — While quiet mode is enabled, when auto-merge is
  blocked by missing App permissions, the system SHALL publish a blocking
  action-required Inbox notification instead of a GitHub comment.
- [x] **QUIET-MODE-006** — While quiet mode is enabled and clarifying-question
  answers can only be persisted in a GitHub comment, when an operator submits
  answers, the system SHALL reject the submission before clearing the issue's
  needs-input state or reporting a successful post.
- [x] **QUIET-MODE-007** — When a project's quiet mode is enabled, the
  PR follow-up completion path (`CompleteExistingPrRunActivity`) SHALL NOT post
  a per-push `## Agent Update` summary comment after the agent pushes to the
  PR branch, including the duplicate-aware idempotency check or LLM summary
  generation, and SHALL still complete the run as usual. When quiet mode is
  disabled, the prior summary-comment behavior SHALL be unchanged.
- [x] **QUIET-MODE-008** — When a project's quiet mode is enabled, the
  agent-facing prompt/runner contract (PR follow-up `Prompts::BuildForPr` and
  issue implementation `PromptAssembly::Sections::IssueTask`) SHALL include
  the quiet-mode commit-message guidance that tells the agent to embed what
  changed, why, and which review feedback was addressed in the commit body
  instead of expecting a follow-up summary comment. The issue implementation
  guidance SHALL be appended as a required assembly section even when a
  project override or pinned `PromptVersion` omits its placeholder; the PR
  follow-up legacy builder SHALL append it in the same case. When quiet mode
  is disabled, the prior prompt SHALL be unchanged (no commit-message guidance
  section is added, and the rendered prompt does not mention quiet mode).
