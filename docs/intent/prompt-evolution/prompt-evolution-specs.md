# EARS Specs: Prompt Evolution

> Testable claims for prompt-version mutation, review, and runtime assignment.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **PROMPT-EVOLUTION-001** — When a prompt requires review, the system
  SHALL persist evolved variants as pending prompt versions with evolution
  provenance and SHALL NOT promote them to `current_version` automatically.
  *Code:* `PromptEvolution::CreateVariants`.

- [x] **PROMPT-EVOLUTION-002** — When a prompt does not require review, the
  system SHALL auto-approve and promote the first evolved variant and SHALL
  auto-resume a quality-paused project when that variant becomes active.
  *Code:* `PromptEvolution::CreateVariants`.

- [x] **PROMPT-EVOLUTION-003** — When a run is covered by a running goal-wrapper
  prompt A/B test, the system SHALL assign the run to a prompt variant before
  rendering the effective prompt and SHALL persist the assigned prompt version
  on the run.
  *Code:* `Activities::RunAgentActivity`.

- [x] **PROMPT-EVOLUTION-004** — When the evolution workflow finds no eligible
  candidates or produces no mutations, the system SHALL stop before creating
  variants or A/B tests and SHALL return the corresponding terminal status.
  *Code:* `Workflows::PromptEvolutionWorkflow`.
