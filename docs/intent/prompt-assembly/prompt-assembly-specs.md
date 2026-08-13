# EARS Specs: Prompt Assembly

> Testable claims for cross-run prompt trust enforcement and quarantine.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **PROMPT-ASSEMBLY-001** — When a GitHub comment's author is an
  allowlisted human collaborator, the system SHALL classify the comment as
  trusted; when the author cannot be proven trusted (missing identity or not
  allowlisted), the system SHALL classify it as excluded rather than trusted.
  *Code:* `PromptAssembly::Trust`, `PromptAssembly::TrustedInput`.

- [x] **PROMPT-ASSEMBLY-002** — When a comment is authored by the project's
  GitHub App bot and carries a recognized Paid-generated marker, the system
  SHALL classify it as trusted; unrecognized bot content and spoofed markers
  from untrusted authors SHALL be excluded.
  *Code:* `PromptAssembly::Trust`.

- [x] **PROMPT-ASSEMBLY-003** — When repository-derived code/docs or knowledge
  content is rendered into a prompt, the system SHALL present it as quarantined
  context with explicit framing that instructions inside the quoted context
  must be ignored.
  *Code:* `PromptAssembly::Section`, `Knowledge::ContextBundle::Build`.

- [x] **PROMPT-ASSEMBLY-004** — When GitHub content is excluded from a prompt,
  the system SHALL represent it only as counts/provenance (kind, source, author,
  reason) and SHALL NOT include its body in prompt text.
  *Code:* `PromptAssembly::TrustedInput`, `PromptAssembly::Result`.

- [x] **PROMPT-ASSEMBLY-005** — When a profile disables optional sections, the
  assembler SHALL still include safety-critical (`required`) sections that are
  applicable.
  *Code:* `PromptAssembly::Profile`, `PromptAssembly::Build`.

- [x] **PROMPT-ASSEMBLY-006** — When a section is missing or declares invalid
  trust metadata, the assembler SHALL fail closed by raising before producing
  prompt text.
  *Code:* `PromptAssembly::Section`, `PromptAssembly::Build`.

- [x] **PROMPT-ASSEMBLY-007** — The prompt trust policy SHALL reuse the
  existing `Project#trusted_github_user?` allowlist (via
  `Prompts::BuildForIssue.fetch_trusted_comments` and
  `Prompts::BuildForPr.select_trusted_comments`) rather than introduce a second
  allowlist policy.
  *Code:* `PromptAssembly::Trust`.

- [x] **PROMPT-ASSEMBLY-008** — The migrated runner-time goal wrappers
  (create-issue, review, enhance-issue, interactive verification) SHALL be
  contributed as explicit `PromptAssembly::Section`s with trust metadata and
  SHALL NOT be appended to the prompt as raw strings outside assembly.
  *Code:* `PromptAssembly::GoalAssembly`,
  `Activities::RunAgentActivity#augment_prompt_for_goal`.

- [x] **PROMPT-ASSEMBLY-009** — A queue-time custom prompt SHALL NOT bypass
  required safety sections: the goal-wrapper assembly runs after
  `effective_prompt` resolves the base text and marks the migrated goal
  sections `required`, so customization cannot suppress them.
  *Code:* `Activities::RunAgentActivity#augment_prompt_for_goal`,
  `PromptAssembly::GoalAssembly`, `PromptAssembly::Profile`.

- [x] **PROMPT-ASSEMBLY-010** — The run metadata SHALL contain a prompt
  assembly digest and section-level provenance (key, source, trust level,
  required flag, inclusion reason) for migrated goals; section bodies SHALL NOT
  be persisted in provenance.
  *Code:* `PromptAssembly::Result#provenance`, `AgentRun#record_prompt_assembly!`,
  `RunProvenanceBuilder#prompt_provenance`.

- [x] **PROMPT-ASSEMBLY-011** — When PR follow-up runs build their prompt,
  the system SHALL assemble sections through `PromptAssembly::Build`,
  classify PR review thread comments and PR conversation comments by
  author trust, exclude untrusted comments from the prompt text, and
  persist the section provenance (included section keys, sources, trust
  levels, required flags, plus excluded counts/reasons) on the
  prepare_pr_prompt phase so the agent run's audit trail shows which
  sections reached the agent and which untrusted content was rejected.
  *Code:* `Prompts::BuildForPr`, `Activities::PreparePrPromptActivity`.
