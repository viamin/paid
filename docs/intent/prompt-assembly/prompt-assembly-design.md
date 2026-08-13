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
