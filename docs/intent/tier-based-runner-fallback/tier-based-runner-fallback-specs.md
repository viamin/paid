# EARS Specs: Tier-Based Runner Fallback

> Testable claims for tier-scoped fallback and resolved-model attempt logging.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **RUNNER-FALLBACK-001** — When a run has a requested model tier, the
  system SHALL treat that tier as the fallback compatibility contract and SHALL
  skip runners that cannot satisfy the tier instead of requiring every runner
  to match a single concrete model id, except that verified model/auth recovery
  may use another tier under RUNNER-FALLBACK-007.
  *Code:* `Activities::RunAgentActivity`, `Runners::ResolveTierModel`.

- [x] **RUNNER-FALLBACK-002** — When a runner attempt resolves a concrete model
  for the requested tier, the system SHALL record the resolved model/provider
  metadata on the attempt entry persisted in `agent_run.runners_attempted`
  and SHALL pass that model explicitly to preflight and execution, including
  subscription-authenticated runners. When a run has no model-selection record
  and the runner has an explicit mid-tier model, the system SHALL resolve and
  pass that model through the same compatibility checks and attempt logging,
  rejecting inactive models or models forbidden by project exclusion, required-model,
  or provider routing policies before execution.
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

- [x] **RUNNER-FALLBACK-004** — When an OpenCode-engine runner's (OpenCode or
  Kilocode) smoke preflight exits non-zero with a local storage failure
  signature (`Failed query: PRAGMA wal_checkpoint` — the state tmpfs was
  filled by a prior long attempt sharing the container), the system SHALL
  wipe and re-seed that CLI's state directory from its image seed
  (`/opt/opencode-seed` / `/opt/kilo-seed`) and retry the smoke once before
  failing the runner, so a poisoned container does not cascade into
  exhausting every sibling runner on the same engine (e.g. run 3537:
  Minimax filled the tmpfs, GLM's preflight then failed in 2.8s).
  *Code:* `Activities::RunAgentActivity#execute_smoke_with_state_repair`,
  `#runner_storage_failure?`, `#repair_runner_state_dir!`.
  *Test:* `spec/temporal/activities/run_agent_activity_spec.rb`.

- [x] **RUNNER-FALLBACK-005** — When a subscription runner has an explicitly
  configured mid-tier model, its Test action SHALL pass that resolved model to
  the harness smoke test with subscription credential isolation. If the model
  is rejected by the provider, the test SHALL use the same explicit, verified
  recovery policy as execution and report the model actually tested.
  *Code:* `Runners::TestAgent`.
  *Test:* `spec/services/runners/test_agent_spec.rb`.

- [x] **RUNNER-FALLBACK-006** — When a runner's preflight, completed transport,
  or streaming abort reports a provider-state failure, the system SHALL classify
  the provider's structured error before diagnostics are truncated: credit
  exhaustion SHALL use the billing backoff path regardless of exit status;
  a Claude `is_error` session-limit envelope SHALL record rate-limited state and
  its harness-parsed reset time even if `subtype` is `success`; and a Codex
  structured subscription-model rejection SHALL be recorded as a configuration
  error without opening the transient circuit breaker. Tool output, prompt
  echoes, fixtures, and ordinary agent prose SHALL not create provider state.
  *Code:* `Activities::RunAgentActivity#raise_classified_provider_state!`.
  *Test:* `spec/temporal/activities/run_agent_activity_spec.rb`,
  `spec/temporal/activities/run_agent_activity_no_db_spec.rb`.

- [x] **RUNNER-FALLBACK-007** — When a provider explicitly rejects a selected
  model for the configured authentication, Paid SHALL discover alternatives
  through agent-harness in the same execution/auth context, apply explicit
  project and operator restrictions, prefer same-tier candidates, permit
  cross-tier recovery, and verify a replacement by successful preflight before
  retrying the current run. Recovery SHALL attempt at most three replacements
  per runner per run within the execution budget before normal runner fallback.

- [x] **RUNNER-FALLBACK-008** — When replacement preflight succeeds, Paid SHALL
  persist that model for the runner/auth/configuration and requested tier, reuse
  it across future runs and catalog refreshes without time-based expiry, and
  repeat recovery on a later model rejection. Reuse SHALL respect current project
  restrictions and explicit configuration changes. Concurrent recovery SHALL
  not overwrite a newer configuration or recovery decision.

- [x] **RUNNER-FALLBACK-009** — When compatibility validation skips a runner or
  runtime model recovery occurs, Paid SHALL record the rejected model, recovery
  outcome, verified replacement and tier change in visible run diagnostics.
  Failed preflights SHALL NOT become durable selections. Expired credentials,
  rate limits, transport errors, and agent prose SHALL NOT trigger model/auth
  recovery or change the configured auth/payment mode.
