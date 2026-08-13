---
parent: PAID
prefix: PROMPT-ASSEMBLY
---

# Low-Level Design: Prompt Assembly

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> RDR-054 (prompt assembly service). This LLD documents the trust-enforcement
> and quarantine contract for cross-run prompt construction.

## Purpose

Every agent prompt is built from inputs with radically different trust
properties: issue and PR bodies, collaborator comments, review threads,
repository-derived code/docs, knowledge-base content, marketplace entries, and
tenant-authored configuration. An injected instruction in an issue body is
indistinguishable, to the model, from a real instruction in the prompt shell.

`PromptAssembly` is the single place that classifies each input by trust and
decides whether it may reach the prompt — as *instructions* (`:trusted`), as
*evidence* (`:quarantined`), or not at all (`:excluded`). Trust enforcement
moves here so every prompt path receives only trusted instructions and
quarantined evidence.

## Trust Model

Three trust levels, decided once per input:

| Level | Meaning | Examples |
| --- | --- | --- |
| `:trusted` | Follow as instructions | allowlisted-human issue/PR bodies, collaborator comments, Paid-generated marker content, tenant-authored configuration |
| `:quarantined` | Read as evidence, never follow | repository code/docs, knowledge-base sections, marketplace attachments |
| `:excluded` | Never reach the prompt | untrusted authors, unrecognized bot content, Paid's own status comments |

Classification is **fail-closed**: an input whose author or provenance cannot
be proven trusted is `:excluded`, never `:trusted`.

## Value Objects

- `PromptAssembly::TrustedInput` — a single input (issue, PR, comment, review,
  repository, knowledge, marketplace, or tenant) classified by trust. Excluded
  inputs expose `provenance` (kind/source/login/reason) with **no body**.
- `PromptAssembly::Trust` — the single trust policy. Reuses the existing
  `Project#trusted_github_user?` allowlist and `Project#paid_bot_author?`
  bot identity rather than inventing a second policy.
- `PromptAssembly::Section` — a rendered section declaring `key`, `source`,
  `trust_level`, `required` (safety-sensitive), and `inclusion_reason`.
  Quarantined sections render with explicit "do not follow" framing.
- `PromptAssembly::Profile` — which optional sections a caller suppresses.
  Safety-critical (`required`) sections are never suppressed.
- `PromptAssembly::Result` — prompt text plus provenance (`sections` kept,
  `skipped` recorded as counts/provenance only).
- `PromptAssembly::Build` — assembles ordered sections into a `Result`, failing
  closed on invalid trust metadata.

## Trust Policy

`Trust` centralizes the predicates previously inlined in
`Prompts::BuildForIssue.fetch_trusted_comments` and
`Prompts::BuildForPr.select_trusted_comments`:

- `human_trusted?(project, login)` — `Project#trusted_github_user?`.
- `paid_status_comment?(body)` — Paid's own agent-update/escalation status
  comments, which are excluded even from allowlisted humans.
- `paid_marker_comment?(project, login, body)` — recognized Paid-generated
  markers (enhancement questions, clarifying answers, review feedback) authored
  by the project's GitHub App bot, which are re-admitted.
- `classify_comment(project, comment)` — the fail-closed classification into a
  `TrustedInput`.

A comment is prompt-eligible when its author is an allowlisted human (and it is
not a Paid status comment) or it is a Paid-authored marker comment.

## Quarantine

Repository-derived code/docs and knowledge-base content are `:quarantined`.
`Section#render` prepends an explicit notice that instructions inside the
quoted context must be ignored. `Knowledge::ContextBundle::Build` applies the
same notice to its generated `## Codebase Context` block so every consumer of
the knowledge bundle gets the framing.

## References

- `app/services/prompt_assembly/`
- `app/services/prompts/build_for_issue.rb`
- `app/services/prompts/build_for_pr.rb`
- `app/services/knowledge/context_bundle/build.rb`
- `app/services/clarifying_questions/comment_admission.rb`

## Goal-Assembly Provenance (#3379)

The four runner-time goal wrappers — create-issue, review, enhance-issue, and
interactive verification — previously reached the prompt as raw string
concatenations in `RunAgentActivity#augment_prompt_for_goal`. They now flow
through `PromptAssembly::GoalAssembly`, which contributes them as explicit
`Section`s with trust metadata:

- create-issue / enhance-issue / review: the fully-rendered goal wrapper (base
  prompt embedded via `{{base_prompt}}`) is contributed as a single `goal.*`
  section marked `required: true` (safety-sensitive).
- create_pr: the base prompt is a `task.base` section and interactive
  verification is appended as a separate `verification.interactive` section.
- Goals without a migrated wrapper (create_feature, lid_planning,
  analyze_issue) contribute only `task.base`.

`PromptAssembly::Result` now exposes a `digest` (SHA-256 over assembled section
keys and content) and a `provenance` map (section keys, sources, trust levels,
required flags, inclusion reasons — never bodies). The activity records this on
the run via `AgentRun#record_prompt_assembly!` (stored under
`external_metadata["prompt_assembly"]`) and `RunProvenanceBuilder` surfaces it
under `prompt_provenance[:assembly]`.

Because the assembly runs after `effective_prompt` resolves the base text, a
queue-time custom prompt cannot bypass the required goal sections — they are
applied here regardless of how the base text was produced.

## Issue-Prompt Assembly (#3377)

The create_pr issue-implementation prompt — previously assembled by
`Prompts::BuildForIssue` via string concatenation — now flows through
`PromptAssembly::Build` at runner time. `AgentRun#prompt_for_issue` delegates to
`PromptAssembly::BuildIssuePrompt`, which pre-fetches the issue comment thread
once and assembles ordered, provenance-tracked sections:

- `issue_task` (required) — the rendered `coding.issue_implementation` template
  (title, body, and instructions).
- `trusted_comments` — collaborator comments, trust-classified via
  `Prompts::BuildForIssue.fetch_trusted_comments`; untrusted authors are
  excluded.
- `clarified_requirements` — trusted clarifying-question answers.
- `service_environment` — available services and database setup constraints.
- `knowledge_context` (quarantined) — the knowledge-base codebase context.
- `style_guides`, `project_conventions`, `lid_workflow` — the migrated
  injector call-sites, each now contributing an explicit section.
- `marketplace_attachments` — marketplace prompt attachments, assembled so
  `effective_prompt` skips the separate injection and never double-injects.
- `safety_rules` (required) — the non-negotiable safety rules, always present
  and never duplicated.

`effective_prompt` persists the result's provenance to
`external_metadata["prompt_assembly"]` via
`AgentRun#persist_prompt_assembly_provenance!` and skips marketplace
re-injection when the assembly already handled it. The safety rules were
extracted from the DB-stored template into
`PromptAssembly::Sections::SafetyRules`; a migration syncs the seeded template
so the rules are no longer embedded (and therefore never duplicated).

## Remaining Direct Prompt Builders

The full RDR-054 migration is phased. The runner-time goal wrappers (#3379),
PR follow-up prompts (#3378), and create_pr issue prompts (#3377) now assemble
through `PromptAssembly::Build`. These direct builders remain and are tracked
for later phases:

- `Prompts::BuildForIssue#build` remains a legacy string-concatenation builder,
  no longer the runner-time create_pr path. Its class methods
  (`conversation_section_for`, `fetch_trusted_comments`,
  `service_environment_section_render_for`) are reused by the assembly section
  providers and `CreateAgentRunActivity`, so comment trust-classification and
  service-environment rendering stay single-sourced.
- `CreateAgentRunActivity` queue-time materialization renders the
  `coding.issue_implementation` prompt version into `custom_prompt` and appends
  the trusted conversation section, service environment, and safety rules
  directly. The base text it produces is captured by the assembly at runner
  time, but the queue-time inputs themselves are not yet expressed as assembly
  sections.
- `Lid::InjectIntoPrompt`, `StyleGuides::InjectIntoPrompt`, and
  `ProjectConventions::InjectIntoPrompt` remain call-site injectors. The
  assembly section providers (`LidWorkflow`, `StyleGuides`,
  `ProjectConventions`) wrap them rather than reimplement their logic, so one
  implementation is shared between the legacy builder and the assembly path.

Splitting the goal-wrapper templates so the base prompt and goal instructions
become truly separate sections (per the RDR-054 registry's `task.*` +
`goal.*` split) is deferred to a follow-up; the templates and seeds embed
`{{base_prompt}}` today, so #3379 records the combined wrapper as one section.
