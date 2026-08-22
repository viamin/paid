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

- [x] **RDR-ROLLOUT-GUARD-003** — When a rollout guard uses a feature flag, RDR
  authoring and implementation prompts SHALL require a reachable enablement
  path: the flag key is added to `FeatureFlags::DEFINITIONS`, the RDR names the
  enablement surface, and runtime behavior is guarded with
  `FeatureFlags.enabled?(:flag_name, project:)`.
  *Tests:* `spec/services/features/rdr_contract_spec.rb`,
  `spec/services/prompts/build_for_create_feature_spec.rb`,
  `spec/services/prompt_assembly/build_issue_prompt_spec.rb`
  *Code:* `Features::RdrContract`, `Prompts::BuildForCreateFeature`,
  `PromptAssembly::Sections::RdrRolloutGuard`
