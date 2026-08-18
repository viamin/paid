# EARS Specs: Model Selection

> Testable claims for run-level model choice and its audit trail.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **MODEL-SELECTION-001** — When a compatible model selection succeeds, the
  system SHALL persist one `ModelSelection` per run with selector metadata,
  ranked candidates, final tier, and any escalation details, and SHALL emit the
  corresponding decision log.
  *Code:* `Models::Select`.

- [x] **MODEL-SELECTION-002** — When meta-agent selection is used, the system
  SHALL choose only from the tier- and provider-compatible candidate pool and
  SHALL route the LLM decision through `AgentHarness.send_message`; when the
  pool contains a single candidate, it SHALL skip the LLM round trip.
  *Code:* `Models::MetaAgentSelector`.

- [x] **MODEL-SELECTION-003** — When rules-based selection is used, the system
  SHALL derive a complexity score, map it to a tier, rank compatible models
  within that tier, and fall back to the broader compatible pool when the tier
  has no active candidates.
  *Code:* `Models::RulesBasedSelector`.

- [x] **MODEL-SELECTION-004** — When the run-level selection contract is
  persisted, the system SHALL require `tier` even when `llm_model` is nil so
  later execution paths can treat the tier as the durable routing contract.
  *Code:* `ModelSelection`.

- [x] **MODEL-SELECTION-005** — When Codex subscription auth is used, the
  system SHALL filter known ChatGPT-Codex-incompatible catalog models before
  default tier selection so queued runs do not dispatch a model the Codex CLI
  rejects at preflight.
  *Code:* `Runners::ModelCompatibility`, `Runners::DefaultTierModelIds`.
