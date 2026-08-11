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

- [x] **RUNNER-FALLBACK-003** — When a container abort originates from a CLI
  streaming `error`/`turn.failed` JSONL event (e.g. a Codex
  `{"type":"error",...}`), the system SHALL inspect the event's payload and:
  (a) classify it as a rate limit when the payload carries a rate-limit/quota
  signal (a real upstream 429/quota can arrive via the JSONL error transport),
  so backoff still applies; otherwise (b) classify it as a generic execution
  error — surfacing the real payload in the message so deterministic config
  faults (model-not-found, outdated CLI) can skip the circuit breaker — and
  SHALL NOT mark the runner rate-limited. An abort matching a configured
  quota/rate-limit output pattern is always classified as a rate limit.
  *Code:* `Containers::Provision::OutputAbortError#source`/`#detail`,
  `StreamingEventProcessor#last_error_message`,
  `Activities::RunAgentActivity#output_abort_rate_limit_error?`.
  *Test:* `spec/temporal/activities/run_agent_activity_spec.rb`.
