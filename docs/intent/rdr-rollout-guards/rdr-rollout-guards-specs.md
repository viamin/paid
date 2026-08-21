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
  guard until the issue or RDR closeout explicitly requests cleanup.
  *Tests:* `spec/services/prompt_assembly/build_issue_prompt_spec.rb`
  *Code:* `PromptAssembly::Sections::RdrRolloutGuard`,
  `PromptAssembly::BuildIssuePrompt`
