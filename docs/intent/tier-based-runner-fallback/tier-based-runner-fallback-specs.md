# EARS Specs: Tier-Based Runner Fallback

> Testable claims for tier-scoped fallback and resolved-model attempt logging.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **RUNNER-FALLBACK-001** — When a run has a requested model tier, the
  system SHALL treat that tier as the fallback compatibility contract and SHALL
  skip runners that cannot satisfy the tier instead of requiring every runner
  to match a single concrete model id.
  *Code:* `Activities::RunAgentActivity`, `Runners::ResolveTierModel`.

- [x] **RUNNER-FALLBACK-002** — When a runner attempt resolves a concrete model
  for the requested tier, the system SHALL record the resolved model/provider
  metadata on the attempt entry persisted in `agent_run.runners_attempted`.
  *Code:* `Activities::RunAgentActivity`, `Runners::ResolveTierModel`.
