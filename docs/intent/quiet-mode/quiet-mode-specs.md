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
- [x] **QUIET-MODE-009** — When a project's quiet mode is enabled, the
  enhance/needs-input flow (`EnhanceIssueActivity#finish_enhance_issue`)
  SHALL write clarifying questions into a marked section of the issue or PR
  description delimited by `<!-- paid:clarifying-questions -->` and
  `<!-- /paid:clarifying-questions -->` instead of posting an enhancement
  comment, while still applying the same label and paid-state updates and
  still rejecting `add_comment` API calls through the project-scoped GitHub
  client. When quiet mode is disabled, the prior enhancement-comment flow
  SHALL be unchanged. A subsequent enhancement run SHALL process its fresh
  agent output when the marked questions have a matching complete marked
  answers section, rather than treating those answered questions as a prior
  incomplete enhancement.
- [x] **QUIET-MODE-010** — When a project's quiet mode is enabled, the
  clarifying-question answer submission path (`Projects::ClarifyingQuestionsController#create`,
  `Tools::SubmitClarifyingAnswers#perform`, and any future quiet-mode-aware
  submission entry point) SHALL converge on a single submission service that
  writes the answers into a marked answers section of the issue/PR
  description (`<!-- paid:clarifying-answers -->` … `<!-- /paid:clarifying-answers -->`),
  preserving any human-written content outside the section, instead of
  issuing a `GitHubClient#add_comment` request. When quiet mode is disabled,
  the prior marker-tagged comment submission path SHALL be unchanged.
- [x] **QUIET-MODE-011** — `ClarifyingQuestions::Load` SHALL resolve pending
  questions and answers from the description sections when present and from
  the marker-tagged GitHub comments otherwise; freshness between a questions
  section and an answers section SHALL be determined by a stable
  question-set digest embedded in the questions section (computed from the
  normalized question text) and a matching digest in the answers section,
  not by `comment.created_at`. When a replacement question set includes
  agent-authored context, that context SHALL be contained in the replaceable
  questions section so context from a prior question set is removed. When the
  project has no quiet mode, the
  comment-based freshness check SHALL remain authoritative and the body
  parsing SHALL NOT regress.
- [x] **QUIET-MODE-012** — `ClarifyingQuestions::IngestAnswers` SHALL
  provide a payload-based entry point (taking answers + notes directly,
  without fetching `issue_comments`) so the description channel and the
  comment channel converge on the same ingestion + `ClearNeedsInput` path.
  When called via the payload path, the system SHALL still apply the same
  knowledge-chunk persistence, idempotent dedup, and `ClearNeedsInput`
  semantics that the comment channel uses.
