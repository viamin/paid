# EARS Specs: RDR Rollout Guards

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each ID
> is a grep target across specs, tests, and code.

- [x] **RDR-ROLLOUT-GUARD-001** — The `create_feature` RDR output contract
  SHALL require a `## Rollout Guard` section in every new RDR document before a
  docs-only RDR PR is opened.
  *Tests:* `spec/integration/create_feature_e2e_spec.rb`
  *Code:* `Features::RdrContract`

- [x] **RDR-ROLLOUT-GUARD-002** — Issue implementation prompts SHALL remind
  agents that RDR-referenced runtime behavior must preserve the RDR's rollout
  guard until the issue or RDR closeout explicitly requests cleanup. An RDR
  reference appearing in the issue title, body, OR a trusted/admitted
  collaborator comment SHALL trigger the guard reminder. References in
  untrusted comments SHALL NOT trigger it.
  *Tests:* `spec/services/prompt_assembly/build_issue_prompt_spec.rb`
  *Code:* `PromptAssembly::Sections::RdrRolloutGuard`,
  `PromptAssembly::BuildIssuePrompt`

- [x] **RDR-ROLLOUT-GUARD-003** — When a rollout guard on a project whose
  repository profile confirms the Paid `FeatureFlags` API uses a feature flag,
  RDR authoring and implementation prompts SHALL require a reachable enablement
  path: the flag key is added to `FeatureFlags::DEFINITIONS`, the RDR names the
  enablement surface, and runtime behavior is guarded with
  `FeatureFlags.enabled?(:flag_name, project:)`.
  *Tests:* `spec/services/features/rdr_contract_spec.rb`,
  `spec/services/prompts/build_for_create_feature_spec.rb`,
  `spec/services/prompt_assembly/build_issue_prompt_spec.rb`
  *Code:* `Features::RdrContract`, `Features::FlagGuardPattern`,
  `Prompts::BuildForCreateFeature`, `PromptAssembly::Sections::RdrRolloutGuard`

- [x] **RDR-ROLLOUT-GUARD-004** — On a project whose repository profile does
  not confirm the Paid `FeatureFlags` API, the `create_feature` RDR output
  contract SHALL NOT require `FeatureFlags::DEFINITIONS` or
  `FeatureFlags.enabled?` artifacts. A rollout guard that names a
  project-appropriate feature flag or config gate with a named enablement
  surface SHALL satisfy the contract, and RDR authoring and implementation
  prompts SHALL instruct the agent to use the repository's own flag/config
  mechanism instead of porting another project's flag system. A Ruby, Rails,
  or undetected project without the API evidence SHALL use this safe default.
  *Tests:* `spec/services/features/rdr_contract_spec.rb`,
  `spec/services/features/flag_guard_pattern_spec.rb`,
  `spec/services/prompts/build_for_create_feature_spec.rb`,
  `spec/services/prompt_assembly/build_issue_prompt_spec.rb`,
  `spec/integration/create_feature_e2e_spec.rb`
  *Code:* `Features::FlagGuardPattern`, `Features::RdrContract`,
  `Prompts::BuildForCreateFeature`, `PromptAssembly::Sections::RdrRolloutGuard`
