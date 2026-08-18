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
- `PromptAssembly::Profile` — which optional sections a caller suppresses,
  the order of optional sections, and budgets for optional context.
  Safety-critical (`required`) sections are never suppressed, reordered to
  weaken safety, or budget-constrained. Carries a content-addressable
  `fingerprint` for deduplication and provenance.
- `PromptAssembly::ProfileResolution` — resolves a profile from global
  defaults through account and project configuration to goal-specific
  overrides. Later levels take precedence; safety sections are always
  enforced regardless of configuration.
- `PromptAssembly::Result` — prompt text plus provenance (`sections` kept,
  `skipped` recorded as counts/provenance only). Includes a SHA-256
  `prompt_digest` of the final text and the `profile_fingerprint`.
- `PromptAssembly::Build` — assembles ordered sections into a `Result`,
  applying profile ordering and budgets, failing closed on invalid trust
  metadata.

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

## Assembly Profiles

Profiles are JSONB-backed and resolve from global defaults through account
and project configuration to goal-specific overrides. No dedicated table is
needed yet — the profile config lives in existing JSONB surfaces
(`tenant_settings.features["prompt_assembly_profile"]` for account scope,
`projects.review_settings["prompt_assembly_profile"]` for project scope).

Resolution order (later levels take precedence):

1. **Global defaults** — `PromptAssembly::Profile.default` provides standard
   budgets for knowledge (4000 tokens) and style guides (32000 bytes).
2. **Account overrides** — read from the account's tenant settings.
3. **Project overrides** — read from the project's review settings.
4. **Goal overrides** — per-goal section policy under the `goals` key in the
   project's profile config.

Each level can set `disabled_sections`, `section_order`, and `budgets`.
`ProfileResolution` merges levels with `Profile#merge`; the result carries a
content-addressable `fingerprint` (SHA-256 of the normalized JSON) for
deduplication and provenance tracking.

Safety enforcement is structural: `Profile#section_enabled?` always returns
`true` for sections whose `required?` flag is set, regardless of what the
profile configuration requests. `Profile#ordered_sections` partitions into
required (fixed order) and optional (profile-ordered) groups, so required
sections can never be pushed past optional ones.

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

## Rollout Gate

The default prompt path is `legacy_prompt_builder`. PromptAssembly is enabled
only when `FeatureFlags.enabled?(:prompt_assembly, project:)` is true. The flag
supports tenant overrides (`tenant_settings.features["prompt_assembly"]`),
project actor gates, and percentage-of-actors rollout through the existing
Flipper-backed `FeatureFlags` service.

`PreparePrPromptActivity` records the selected path on the prepare phase and
on `agent_runs.external_metadata["prompt_builder"]`. `RunAgentActivity` records
the same field when it applies runner-time goal augmentation. PromptAssembly
provenance is persisted only for the `prompt_assembly` cohort; legacy runs keep
the existing prompt-version, service-environment, style-guide, marketplace,
token, status, and timing records.

Before rollout increases, compare cohorts by joining `agent_runs` and
`token_usages` on the recorded builder:

- PR completion/merge rate.
- Follow-up run count per PR.
- Token usage and cost per PR.
- `no_output` and terminal failure rate.
- Time to merge or escalation.

For prompt-text parity investigation, `prompt_assembly_shadow_compare` may be
enabled separately. It builds both PR prompt paths for the same run input,
serves only the selected builder's prompt, and stores a capped data-only
comparison under
`agent_run_phases.metadata["prompt_builder_comparison"]`. The comparison
contains the served builder, SHA-256 digests, byte counts, capped prompt
samples, and a match boolean. There is no dedicated UI; the data is inspected
from phase metadata.

Because the assembly runs after `effective_prompt` resolves the base text only
inside the flagged path, a queue-time custom prompt cannot bypass required goal
sections for enabled cohorts. Legacy cohorts keep the previous raw string
augmentation behavior.

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

The full RDR-054 migration is phased. The runner-time goal wrappers (#3379)
and PR follow-up prompts (#3378) assemble through `PromptAssembly::Build` only
for flagged rollout cohorts; create_pr issue prompts (#3377) assemble through
`PromptAssembly::Build` at runner time. These direct builders remain and are
tracked for later phases:

- `Prompts::BuildForIssue#build` remains a legacy string-concatenation builder,
  no longer the runner-time create_pr path. Its class methods
  (`conversation_section_for`, `fetch_trusted_comments`,
  `service_environment_section_render_for`) are reused by the assembly section
  providers and `CreateAgentRunActivity`, so comment trust-classification and
  service-environment rendering stay single-sourced.
- `CreateAgentRunActivity` still resolves and records the selected
  `coding.issue_implementation` prompt version at queue time, but it no longer
  materializes a `create_pr` issue prompt into `custom_prompt`. The queued run
  carries the chosen prompt version for audit and the runner-time assembly
  renders the issue task, comments, service environment, and safety rules as
  explicit sections instead.
- `Prompts::BuildForPr` uses legacy string concatenation by default for PR
  follow-up prompts, with PromptAssembly available only through the rollout
  gate. Broad production use requires the measured rollout above.
- `Lid::InjectIntoPrompt`, `StyleGuides::InjectIntoPrompt`, and
  `ProjectConventions::InjectIntoPrompt` remain call-site injectors. The
  assembly section providers (`LidWorkflow`, `StyleGuides`,
  `ProjectConventions`) wrap them rather than reimplement their logic, so one
  implementation is shared between the legacy builder and the assembly path.

Splitting the goal-wrapper templates so the base prompt and goal instructions
become truly separate sections (per the RDR-054 registry's `task.*` +
`goal.*` split) is deferred to a follow-up; the templates and seeds embed
`{{base_prompt}}` today, so #3379 records the combined wrapper as one section.
