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

- [x] **ISSUE-ANALYSIS-013** — Every provider-attempt failure inside `call_llm`
  (raised or response-shaped) SHALL persist a structured `AgentRunLog` entry
  (`log_type: "system"`, `metadata["type"] == AgentRunLog::PROVIDER_FAILURE_TYPE`)
  carrying the provider, attempt number, a normalized `failure_category`
  (the same taxonomy `ISSUE-ANALYSIS-007`/`ISSUE-ANALYSIS-009` already use for
  circuit-breaker classification), and an exit code when known — with the
  message run through `AgentRun::ErrorMessageSanitizer` so secrets and
  unbounded provider payloads are never persisted. The final
  provider-exhaustion error SHALL summarize every attempted provider and its
  normalized category instead of only the provider name list. Log persistence
  failures SHALL be rescued and warn-logged rather than breaking the failover
  loop. `AgentRunLog.provider_failures` / `.provider_failure_categories` SHALL
  allow grouping on the structured category rather than free-text messages,
  and `AgentRunPatterns::Detect` SHALL cluster analyze-issue
  provider-exhaustion failures on the run's normalized failure-category set
  (category names only — never provider names or attempt counts), degrading to
  the stable exhaustion prefix when structured logs are missing, so clustering
  stays stable even though the terminal error text now includes
  provider-specific detail.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb`
  ("persists a structured AgentRunLog entry for the failed provider attempt",
  "redacts and truncates secrets out of the persisted provider-failure message"),
  `spec/models/agent_run_log_spec.rb` (".provider_failures", ".provider_failure_categories",
  ".provider_failure_categories_by_run"),
  `spec/services/agent_run_patterns/detect_spec.rb`
  ("clusters analyze_issue provider-exhaustion failures on normalized failure categories instead of provider names",
  "clusters provider-exhaustion failures on the stable prefix when structured provider-failure logs are missing").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#record_provider_attempt_failure!`,
  `#failure_category_for`, `#issue_analysis_provider_exhaustion_message`,
  `app/models/agent_run_log.rb`, `app/services/agent_run_patterns/detect.rb`.

## Trust and response contract

- [x] **ISSUE-ANALYSIS-004** — The system SHALL reject untrusted issues and
  filter issue comments before any LLM call: trusted-user allowlist comments
  plus `ClarifyingQuestions::CommentAdmission` (Paid's own bot-authored
  enhancement/answer marker comments, whose app-bot login is unspoofable).
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

- [x] **ISSUE-ANALYSIS-014** — The readiness assessor SHALL see the prior
  cycle state when re-evaluating an issue (enhancement round count, prior
  verdict, prior missing-context areas, and a summary of the latest Paid
  enhancement marker comment) and SHALL admit Paid's own structured
  enhancement/answer marker comments to its prompt via the existing
  clarifying-question admission, so re-evaluation is a delta against the
  previous cycle rather than a repeat of the baseline (#3842). The cycle-state
  summary SHALL filter through `ClarifyingQuestions::CommentAdmission.paid_marker_comment?`
  (bot author + marker body) — the marker alone is not a trust signal, and an
  untrusted commenter's spoofed marker comment must not reach the prompt. The
  assessor SHALL be calibrated to treat codebase-resolvable ambiguity as non-blocking
  (the `create_pr` agent self-answers it), to prefer `sufficient_context:
  true` when prior rounds produced implementation context without a fresh
  human signal, and to default to `sufficient_context: true` when the round
  cap has been reached so the issue moves to `create_pr` instead of being
  parked in `manual_review`. The verdict SHALL be persisted on the issue
  (`last_analyzer_sufficient_context`, `last_analyzer_reasoning`,
  `last_analyzer_missing_context_areas`, `last_analyzed_at`) so operators
  can diagnose a lane stuck in `manual_review` without re-reading the
  run's stdout and so the next cycle's prompt can include it as cycle state.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb` ("admits the app bot's enhancement marker comments", "still rejects the app bot's non-marker comments", "rejects spoofed enhancement marker comments from untrusted users in cycle state", "threads prior cycle state", "persists the verdict and reasoning on the issue", "includes calibration guidance").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#trusted_comments`,
  `#prompt_for`, `#cycle_state_section`, `#build_cycle_state`,
  `#latest_bot_enhancement_comment`, `#enhancement_summary_text`, `#persist_verdict!`.

- [x] **ISSUE-ANALYSIS-015** — The round-cap calibration guidance in
  `ISSUE-ANALYSIS-014` is a prompt-only instruction, so the readiness
  assessor's `sufficient_context` verdict SHALL be overridden
  deterministically in code, not left to instruction-following: when at
  least one enhancement round has run (`enhance_issue_rounds > 0`) AND
  the counter has reached the project's
  `max_enhance_issue_reevaluation_rounds` and no trusted human has
  commented since the analyzer's own previous pass, the system SHALL
  force `sufficient_context: true` (and clear `missing_context_areas`)
  regardless of the model's raw verdict, so the issue proceeds to
  `create_pr` instead of having its `enhance_issue` follow-up rejected
  at queue time
  (`QueueAgentRunActivity#enhancement_round_limit_reached?`) and
  re-parked in `manual_review` on LLM noncompliance alone (#3849,
  follow-up to #3842/#3844). The `enhance_issue_rounds > 0` precondition
  preserves the cap-0 semantics: `max_enhance_issue_reevaluation_rounds
  = 0` disables automatic enhancement, so `0 >= 0` must not let the
  override fire on the very first analysis — a `sufficient_context:
  false` verdict keeps its queue-time rejection and the issue stays
  parked in `manual_review` for a human to gate. The fresh-signal
  anchor SHALL be the issue's `last_analyzed_at` timestamp (written only
  by `#persist_verdict!`, never derived from GitHub content), because it
  exists for both credential models — anchoring on the bot-authored
  enhancement marker comment made the carve-out dead code for PAT-backed
  projects, where `Project#paid_bot_author?` is always false and no
  marker comment is ever admitted. Paid's own structured marker comments
  (enhancement, clarifying-answers, stop-for-manual-review) SHALL be
  excluded from the fresh-signal scan by body marker, so that on
  PAT-backed projects — where Paid posts as the allowlisted PAT user —
  its own comments never read as fresh human signal (which would reopen
  the budget on every cycle and turn the cap into an infinite enhance
  loop); a spoofed marker can only exclude the spoofing comment itself
  from the scan, never admit content into the prompt (admission stays
  gated by `ClarifyingQuestions::CommentAdmission`, #3842). The override
  SHALL NOT apply when the model already returned
  `sufficient_context: true`, nor when a trusted human commented after
  the last analyzer pass — that fresh signal warrants a real
  re-evaluation rather than a forced one. Because a plain trusted
  comment matches none of the counter-reset paths (the answer flow, a
  needs-input label removal, or a trusted body edit via
  `ISSUE-ENHANCEMENT-015`), the counter can still sit at cap when this
  suppression fires — in that case the system SHALL reset
  `enhance_issue_rounds` to 0, preserving the invariant "suppression ⇒
  counter below cap" so the re-evaluation `enhance_issue` follow-up
  queues instead of being rejected at queue time and re-parking the
  issue in `manual_review` (#3849 acceptance criterion 1). The raw LLM
  verdict and the override SHALL both be logged
  (`agent_execution.analyze_issue_cap_override`,
  `agent_execution.analyze_issue_enhancement_budget_reopened`) for
  observability. No test SHALL depend on the LLM obeying the
  prompt-level cap instruction.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb`
  ("forces sufficient_context: true regardless of the LLM's raw verdict",
  "persists the overridden verdict, not the LLM's raw false",
  "does not override when a trusted human commented after the last enhancement round",
  "does not override on a PAT-backed project when a trusted human commented after the last analysis",
  "still overrides on a PAT-backed project when the only newer comment is Paid's own enhancement marker posted as the PAT user",
  "keeps the manual_review gate when the round cap is zero",
  "resets the round counter when suppression fires so the enhance_issue follow-up can queue",
  "still overrides when the only post-enhancement comment is untrusted",
  "does not override when the LLM already returned sufficient_context: true",
  "does not override sufficient_context: false when the round cap has not been reached").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#enforce_cap_override`,
  `#reopen_enhancement_budget!`, `#fresh_human_signal_since?`,
  `#paid_marker_comment_body?`, `#build_cycle_state`.
