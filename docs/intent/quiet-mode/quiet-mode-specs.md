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
