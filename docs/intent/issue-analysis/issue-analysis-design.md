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
across the fleet can rate-limit every candidate in the same window. A provider
attempt inside the loop can fail two different ways, and both SHALL update the
circuit breaker (`ISSUE-ANALYSIS-007`):

- **Raised `AgentHarness::Error`.** `AgentHarness.send_message` raises when
  the transport itself detects the failure (e.g. the HTTP text-mode path used
  for `claude` on 401/429 responses).
- **Unsuccessful response, no exception.** CLI-backed providers (Codex,
  OpenCode, and `claude` outside text mode) normally report a nonzero exit as
  a `Response` with `success?` false and an `error` string, not as a raised
  exception. `call_llm` detects this case inside the tracked provider-attempt
  phase and promotes it to an internal `UnsuccessfulResponseError`, which then
  flows through the same rescue clauses as a raised error. Before the
  `UnsuccessfulResponseError` bridge, the equivalent check ran *after* the
  phase block returned normally, so `agent_run_phases` and
  `issue_analysis_diagnostics` recorded the attempt as `completed` even when
  it had failed — and a later timeout during the failover provider would
  leave behind a misleading history that pinned the failing provider with a
  `completed` status. Before #3639, the failure was logged and the loop moved
  on without ever touching the circuit breaker, so deterministically broken
  runners never opened and stayed eligible across every subsequent
  `analyze_issue` run.

Both paths funnel through the same classification so a provider's circuit
state doesn't depend on which mechanism a given provider happens to use for a
given failure:

- Rate-limit-shaped (raised `AgentHarness::RateLimitError`, or a response
  whose `error` text classifies as `:rate_limited` via
  `AgentHarness::ErrorTaxonomy.classify_message`) → `RunnerState#mark_rate_limited!`
  records a reset time (the exception's `reset_time`, or
  `RunnerSupport.rate_limit_reset_at` parsed from the response text) so the
  provider is excluded from `chat_providers` on the next attempt until the
  window clears.
- Authentication-shaped (raised `AgentHarness::AuthenticationError`, or a
  response classified `:auth_expired`) → `RunnerState#record_failure!` with
  `threshold: 1`, opening the circuit immediately (`ISSUE-ANALYSIS-009`).
  Unlike a transient error, a stale credential will not start working again
  on the next attempt, so there is no reason to spend the owner's configured
  failure budget rediscovering that on every run.
- Anything else → `RunnerState#record_failure!` increments the provider's
  circuit-breaker failure count, using the owner's configured
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

## Automatic retry backoff after provider exhaustion

Non-rate-limit provider exhaustion is still an availability outage, but unlike
`ISSUE-ANALYSIS-006` it does not have a provider-supplied reset time. When an
**automatic** `analyze_issue` run fails with provider exhaustion
(`ISSUE-ANALYSIS-010`), the issue records a bounded next-attempt timestamp on
the `issues` row itself. The normal `paid_state = "failed"` re-enqueue hook is
reused, but its delay is overridden to that persisted next-attempt time so the
issue does not immediately re-enter auto-pick and churn.

The backoff is issue-local and capped: repeated automatic exhaustion failures
for the same issue grow the wait window exponentially up to a fixed maximum.
This keeps multiple eligible issues from amplifying one provider outage into an
unbounded retry storm while still guaranteeing another bounded attempt later.

The cooldown is only for automatic selection. Manual retries remain allowed
(`ISSUE-ANALYSIS-011`) because they do not flow through auto-pick eligibility.
However, a manual retry failure does not extend or clear the automatic cooldown
by itself; only a successful provider call clears it.

## Timeout diagnostics and timeout policy

The `analyze_issue` activity has a 10-minute workflow-level
`start_to_close_timeout`, but it now records finer-grained sub-phases beneath
that envelope so a timeout can be classified without log spelunking:

- knowledge search
- context-bundle construction
- each provider attempt

Each sub-phase is persisted to `agent_run_phases` with its own timing metadata
and budget marker. In parallel, the run stores the latest known analyze-issue
phase/provider summary in `external_metadata["issue_analysis_diagnostics"]`
before the sub-phase starts, so a hard activity timeout still leaves behind the
last phase/provider the worker had entered even if the process never reaches the
phase-recording `ensure`.

Direct provider attempts run under `with_periodic_heartbeat`, which means
Temporal cancellation is cooperative during the LLM call rather than waiting
for the outer activity timeout. This heartbeat does **not** replace the
`start_to_close_timeout`; it only keeps cancellation responsive while the
provider call is in flight.

Timed-out **automatic** `analyze_issue` runs remain a plain failure, not an
automatic retry or parked state (`ISSUE-ANALYSIS-012`). The only automatic park
path is the already-classified all-rate-limited case (`ISSUE-ANALYSIS-006`),
where the system has a concrete recovery time. A generic activity timeout is
still ambiguous after the first incident; with only one observed run, the safe
policy is to fail it loudly with retained phase/provider diagnostics rather than
assume it should churn in place or self-retry.

Clearing conditions:

- A successful `call_llm` provider response clears the issue-level exhaustion
  cooldown immediately, before JSON parsing, because provider availability has
  already recovered even if the response body later proves malformed.
- Relevant owner-side runner changes invalidate the cooldown for auto-pick
  eligibility: the owner's issue-analysis runner selection, available chat
  runners, runner-state health snapshots, and runner authentication material
  (provider API keys / integration credentials) all contribute to a reset
  context timestamp. If that timestamp is newer than the recorded backoff, the
  issue is treated as immediately eligible again without waiting for the
  original timer to elapse.

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
