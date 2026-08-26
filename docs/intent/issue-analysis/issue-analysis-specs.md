# EARS Specs: Issue Analysis

> Testable claims for the `analyze_issue` goal. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r ISSUE-ANALYSIS-002`).

## Provider selection and fallback

- [x] **ISSUE-ANALYSIS-001** — When auto-pick selects an issue on a project
  with auto-enhance enabled, the system SHALL perform an LLM readiness
  assessment using the owner's issue-analysis runner selection, falling back to
  the owner's chat-enabled runner(s), filtered by circuit-breaker / rate-limit
  availability.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb` ("issue analysis runner selection"),
  `spec/services/knowledge/provider_selector_spec.rb` (".for_issue_analysis").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#chat_providers`,
  `app/services/knowledge/runner_selector.rb#for_issue_analysis`.

- [x] **ISSUE-ANALYSIS-002** — When the configured issue-analysis runner is
  unavailable (rate-limited or circuit-open), the analysis SHALL widen to an
  available chat-enabled runner the owner has, rather than forcing a hardcoded
  platform default (the old Anthropic-only `DEFAULT_PROVIDER`) back into the
  candidate list. The owner's configured runners are the only source of
  candidates — no runner is assumed when none is available.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb` ("provider fallback", "does not force claude"),
  `spec/services/knowledge/provider_selector_spec.rb` (".available_chat_runner_keys").
  *Code:* `app/services/knowledge/runner_selector.rb#available_chat_runner_keys`,
  `app/temporal/activities/analyze_issue_activity.rb#chat_providers`.

- [x] **ISSUE-ANALYSIS-003** — When no chat runner is available at all (the
  candidate list itself is empty), the system SHALL fail the run loudly with a
  non-retryable `AnalyzeIssueLlmFailed` error instead of masking the outage by
  targeting a known-unhealthy provider. This is distinct from `ISSUE-ANALYSIS-006`,
  where candidates exist but all attempts fail transiently.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb` ("raises when no chat runner is available").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#call_llm`.

- [x] **ISSUE-ANALYSIS-006** — When every attempted provider fails specifically
  because it is rate-limited (a transient, simultaneous-rate-limit outage
  rather than a permanent failure), the system SHALL park the run as
  `rate_limited` with a computed recovery time (`agent_run.rate_limit!`)
  instead of raising a non-retryable error. This mirrors the `create_pr`
  runner path: `StaleRunDetectorJob` re-queues the run once its
  `rate_limited_until` window elapses, so the analysis retries automatically
  instead of requiring a human to manually re-trigger it. A mix of rate-limit
  and non-rate-limit failures, or an empty candidate list, keeps the existing
  non-retryable `AnalyzeIssueLlmFailed` error (`ISSUE-ANALYSIS-003`).
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb` ("provider rate limiting").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#call_llm`, `#raise_llm_failure!`.

- [x] **ISSUE-ANALYSIS-007** — Every provider failure encountered inside
  `call_llm` SHALL update that provider's `RunnerState` circuit-breaker record,
  whether the failure surfaces as a raised `AgentHarness::Error` or as a
  `response.success? == false` result with no exception raised — the latter is
  how CLI-backed providers normally report a nonzero exit. The
  `UnsuccessfulResponseError` bridge inside `call_llm` promotes the
  response-shaped failure to an exception so it is detected *inside* the
  tracked phase block; without that bridge the phase recorder would mark the
  attempt as `completed` and a later timeout during the failover provider
  would pin the wrong provider/status in the run's phase history
  (`ISSUE-ANALYSIS-012`). Before #3639 the failure was logged and the loop
  moved on without ever touching the circuit breaker, letting deterministically
  broken runners stay circuit-closed indefinitely. Both paths classify the
  failure the same way: rate-limit-shaped failures call `mark_rate_limited!`
  (`ISSUE-ANALYSIS-007`), authentication-shaped failures open the circuit
  immediately (`ISSUE-ANALYSIS-009`), and everything else calls
  `record_failure!` at the owner's configured threshold.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb` ("provider rate limiting", "unsuccessful provider responses", "provider fallback").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#call_llm`,
  `#record_response_failure`, `#classify_response_error`,
  `#record_runner_rate_limit`, `#record_runner_failure`.

- [x] **ISSUE-ANALYSIS-009** — When a provider failure — raised
  (`AgentHarness::AuthenticationError`) or returned as an unsuccessful
  response whose error text classifies as `:auth_expired`
  (`AgentHarness::ErrorTaxonomy.classify_message`) — is authentication-shaped,
  the system SHALL open that provider's circuit breaker immediately
  (`record_failure!(threshold: 1, ...)`) instead of counting it toward the
  owner's generic failure threshold. Authentication failures are deterministic
  (the credential will not spontaneously start working on retry), so waiting
  for the generic threshold wastes attempts against a provider known to be
  broken until the owner reconnects it.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb` ("unsuccessful provider responses", "provider rate limiting").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#call_llm`,
  `#record_runner_auth_failure`.

- [x] **ISSUE-ANALYSIS-010** — When an **automatic** `analyze_issue` run fails
  because every analysis provider is unavailable and no provider call succeeds,
  the system SHALL persist a bounded next-attempt time on the issue and exclude
  the issue from auto-pick until that time. The backoff SHALL grow per issue
  across consecutive automatic provider-exhaustion failures, SHALL be capped,
  and SHALL be invalidated when a later successful provider call happens or
  when the owner's relevant issue-analysis runner configuration, runner-health
  state, or authentication material changes.
  *Tests:* `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`,
  `spec/temporal/activities/analyze_issue_activity_spec.rb`,
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/models/issue.rb`, `app/temporal/activities/analyze_issue_activity.rb`,
  `app/temporal/activities/mark_agent_run_failed_activity.rb`,
  `app/services/automation/strategies/auto_pick/default_candidate_source.rb`,
  `app/services/issues/issue_analysis_backoff_reset_context.rb`.

- [x] **ISSUE-ANALYSIS-011** — Manual retries of failed `analyze_issue` runs
  SHALL remain available even while the issue is under automatic
  provider-exhaustion backoff. Manual failures SHALL NOT extend or clear that
  automatic cooldown; only a successful provider call clears it.
  *Tests:* `spec/requests/agent_runs_spec.rb`,
  `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`.
  *Code:* `app/controllers/projects/agent_runs_controller.rb`,
  `app/temporal/activities/mark_agent_run_failed_activity.rb`,
  `app/models/issue.rb`.

- [x] **ISSUE-ANALYSIS-012** — When `AnalyzeIssueActivity` approaches or
  exceeds its 10-minute outer timeout, the system SHALL persist sub-phase
  timing for knowledge search, context-bundle construction, and each provider
  attempt, and SHALL retain the last known analyze-issue phase/provider in run
  diagnostics so a generic Temporal timeout can still be categorized. A timed
  out automatic analysis SHALL remain a failed run, not an automatic retry or
  parked state, unless the failure had already been positively classified as
  the all-rate-limited case in `ISSUE-ANALYSIS-006`.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb`,
  `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`.
  *Code:* `app/temporal/activities/base_activity.rb`,
  `app/temporal/activities/analyze_issue_activity.rb`,
  `app/temporal/activities/mark_agent_run_failed_activity.rb`,
  `app/models/agent_run.rb`,
  `app/models/agent_run_phase.rb`.

- [x] **ISSUE-ANALYSIS-008** — When no explicit issue-analysis runner is
  configured and the broadening fallback (`available_chat_runner_keys`) is
  used, economical (lean) runners SHALL be ordered before heavy-exploration
  runners so a lightweight assessment call does not burn tokens on a
  heavy-exploration runner. The candidate list is reordered via
  `RunnerSupport.lean_first`; the set of available candidates is not narrowed.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb` ("prefers an economical runner over claude in the fallback path").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#chat_providers`,
  `RunnerSupport.lean_first`.

## Trust and response contract

- [x] **ISSUE-ANALYSIS-004** — The system SHALL reject untrusted issues and
  filter issue comments through the trusted-user allowlist before any LLM call.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb` ("rejects untrusted issues", "filters untrusted issue comments").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#ensure_trusted_issue!`, `#trusted_comments`.

- [x] **ISSUE-ANALYSIS-005** — The system SHALL surface malformed or
  incomplete analysis JSON as a non-retryable `AnalyzeIssueInvalidJson` error.
  A markdown code fence around the JSON (```` ```json ... ``` ````, including a
  trailing newline after the closing fence) SHALL be normalized away before
  parsing, so a fenced-but-otherwise-valid response is not mistaken for a
  failure.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb` ("malformed JSON", "missing required keys", "strips a markdown code fence").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#parse_response!`, `#extract_analysis_json`.
