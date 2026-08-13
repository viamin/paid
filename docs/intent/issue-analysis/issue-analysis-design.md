---
parent: PAID
prefix: ISSUE-ANALYSIS
---

# Low-Level Design: Issue Analysis

> Companion to the high-level design (`docs/high-level-design.md`). This is the
> LLD for the `analyze_issue` goal — the lightweight, container-free LLM
> readiness assessment Paid runs when auto-pick selects an issue on a project
> with auto-enhance enabled.

## Purpose

Before committing to a full `create_pr` agent run (clone, container, agent),
Paid asks an LLM whether the issue plus the knowledge base give an autonomous
agent enough to start. This is a single direct LLM call — no Docker, no repo
clone — implemented by `Activities::AnalyzeIssueActivity`.

## Provider selection

The analysis call does **not** use the agent run's assigned runner. Runner
assignment (including dispatch reroute / fallback) governs *which runner
executes the agent container*; the analysis activity resolves its own LLM
provider independently, through the knowledge/chat provider layer:

1. **Issue-analysis preference.** `Knowledge::ProviderSelector.for_issue_analysis`
   reads the owner's `issue_analysis_runner` + `issue_analysis_fallback_runners`,
   filtered by circuit breaker / rate-limit availability (`RunnerState#unavailable?`).
   This is a user-configurable selection of which API keys are eligible for the
   assessment; it is blank by default.
2. **Broadening.** When the preference yields no candidates (none configured or
   the configured runner is unavailable), `Knowledge::ProviderSelector.available_chat_runner_keys`
   widens to every chat-enabled `Runner` the owner actually has, applying the
   same availability filter. This is what lets an analysis succeed on `codex`
   when `claude` is rate-limited, and what serves the default case where no
   explicit issue-analysis runner is set. The widened list is then reordered via
   `RunnerSupport.lean_first` so economical runners are tried before
   heavy-exploration ones (`ISSUE-ANALYSIS-008`) — a lightweight assessment
   call does not need aggressive codebase exploration, so it should not burn
   tokens landing on `claude` when `codex` / `opencode` / `omp` is available.
   The candidate set is not narrowed; every available chat runner remains
   eligible if the lean runners fail.

There is no hardcoded platform default. The previous design forced
`[DEFAULT_PROVIDER]` ("claude") whenever the candidate list was empty, which
silently routed the call onto an Anthropic-only credential path
(`ANTHROPIC_API_KEY` in the host ENV) even when the owner had other valid API
keys configured. That is the run-17220 / RDR-052 failure mode this segment now
guards against (see `ISSUE-ANALYSIS-002`): analysis selects from the owner's
configured runners rather than assuming Anthropic.

If no provider is available at all, `call_llm` raises a non-retryable
`AnalyzeIssueLlmFailed` ("No LLM provider produced an issue analysis") rather
than silently masking the outage.

## Transient rate-limit handling and circuit-breaker recording

Candidates existing in `chat_providers` does not guarantee they still succeed
by the time `call_llm` actually calls them — the availability filter reads a
circuit-breaker snapshot taken before the loop starts, and a burst of traffic
across the fleet can rate-limit every candidate in the same window. Two things
happen when a provider attempt fails inside the loop (`ISSUE-ANALYSIS-007`):

- `AgentHarness::RateLimitError` → `RunnerState#mark_rate_limited!` records
  the provider's `reset_time` so it is excluded from `chat_providers` on the
  next attempt (this run's retry or a later one) until the window clears.
- Any other `AgentHarness::Error` → `RunnerState#record_failure!` increments
  the provider's circuit-breaker failure count, using the owner's configured
  threshold/decay window, same as `Knowledge::RunnerExecutor`.

When every attempted provider in the candidate list failed and every one of
those failures was a rate-limit error (`ISSUE-ANALYSIS-006`), the outage is
transient rather than permanent. Instead of raising a non-retryable error,
`call_llm` calls `agent_run.rate_limit!(error:, reset_at:)` — the same
model-level state `create_pr`'s `run_agent` uses when all runners are
rate-limited — and raises a `RateLimit`-typed `ApplicationError`.
`StaleRunDetectorJob` already re-queues any run parked in `rate_limited` once
`rate_limited_until` passes (`AgentRun#rate_limited_due`), so the analysis
retries automatically once providers recover instead of requiring a human to
manually re-trigger it. Any other outcome (a genuine mix of failure types, or
an empty candidate list to begin with) keeps the original non-retryable
`AnalyzeIssueLlmFailed` behavior — those are not transient rate-limit storms.

## Inputs and trust

- The issue must be trusted (`issue.trusted?`); untrusted issues are rejected
  before the LLM is called.
- Issue comments are filtered through the project's trusted-user allowlist.
- Knowledge search and context-bundle failures degrade gracefully (empty
  context) rather than aborting the assessment.

## Response contract

The LLM returns JSON: `sufficient_context` (bool), `reasoning` (string),
`missing_context_areas` (array). Malformed or incomplete JSON is a non-retryable
`AnalyzeIssueInvalidJson` error; the harness is trusted to deliver clean
`response.output`, not Paid.
