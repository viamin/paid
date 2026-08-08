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

- [x] **ISSUE-ANALYSIS-003** — When no chat runner is available at all, the
  system SHALL fail the run loudly with a non-retryable `AnalyzeIssueLlmFailed`
  error instead of masking the outage by targeting a known-unhealthy provider.
  *Tests:* `spec/temporal/activities/analyze_issue_activity_spec.rb` ("raises when no chat runner is available").
  *Code:* `app/temporal/activities/analyze_issue_activity.rb#call_llm`.

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
