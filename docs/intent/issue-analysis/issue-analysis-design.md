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

## Durable per-provider failure records

Prior to #3641, the per-provider errors that `call_llm` classifies (see below)
were only ever written to the process log via `logger.warn` — useful while a
worker is live, gone once the log rotates. When every candidate provider fails
for a *different* reason (an OpenCode binary architecture mismatch, an
unauthenticated `claude`, an incompatible Codex model), the run detail and
failure-pattern systems could only see the generic exhaustion message, not the
distinct root causes an operator needs to act on.

Every provider-attempt failure inside `call_llm` — raised
(`AgentHarness::RateLimitError`, `AgentHarness::AuthenticationError`, any other
`AgentHarness::Error`) or response-shaped (`UnsuccessfulResponseError`) —
SHALL also persist a structured `AgentRunLog` entry (`ISSUE-ANALYSIS-013`) via
`record_provider_attempt_failure!`, using the existing `log_type: "system"` +
`metadata["type"]` discriminator convention (mirrors `Models::Select`'s
`model_selection_decision` entries) rather than adding a new `log_type` value:

- `metadata["type"]` — `AgentRunLog::PROVIDER_FAILURE_TYPE`
  (`"issue_analysis_provider_failure"`)
- `metadata["provider"]`, `metadata["attempt"]`
- `metadata["failure_category"]` — a normalized category, not raw provider
  text: the raised error's own `error_category` when it has one (e.g.
  `ProviderInstallationError` defaults to `:installation`, which is exactly
  the OpenCode-architecture-mismatch bucket), `:rate_limited` /
  `:auth_expired` for their dedicated rescue clauses, otherwise
  `AgentHarness::ErrorTaxonomy.classify(error)` / `.classify_message(response.error)`
  — the same taxonomy `record_response_failure` already uses for circuit-breaker
  classification (`ISSUE-ANALYSIS-007`/`ISSUE-ANALYSIS-009`), so the category
  on the durable record always agrees with the category that drove the circuit
  breaker.
- `metadata["exit_code"]` — present only for response-shaped failures, where
  `AgentHarness::Response#exit_code` is meaningful.
- `content` — the provider's error message run through
  `AgentRun::ErrorMessageSanitizer.call` (the same redaction/truncation
  pipeline already used for `runners_attempted` entries), never the raw
  payload, so secrets and unbounded text never reach a durable record.

Persisting the log entry itself is best-effort: a failure to write it is
rescued and logged as a warning rather than allowed to break the failover
loop, mirroring `Models::Select#persist_agent_run_decision_log`.

`AgentRunLog.provider_failures` scopes to these entries and
`AgentRunLog.provider_failure_categories(agent_run_ids)` groups them by
`failure_category`. `AgentRunLog.provider_failure_categories_by_run` keeps the
same data per run so `AgentRunPatterns::Detect` can cluster analyze-issue
provider-exhaustion incidents on the run's normalized category set — category
names only; provider names and attempt counts never participate in the cluster
key — instead of the variable provider detail embedded in the terminal error
text. When the structured logs are missing (log persistence is best-effort),
the detector degrades to the stable bare exhaustion prefix rather than the
free-text message.

The final provider-exhaustion error (`issue_analysis_provider_exhaustion_message`)
now summarizes every attempted provider and its normalized category —
`"All issue-analysis providers exhausted: opencode (installation), claude
(auth_expired), codex (permanent)"` — instead of just the provider name list,
so the terminal error itself is actionable without cross-referencing
`agent_run_logs`. It never includes raw provider error text.

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
- Issue comments are filtered through `ClarifyingQuestions::CommentAdmission`
  so that the prompt admits trusted human collaborators plus Paid's own
  structured marker comments authored by the project's GitHub App bot
  (enhancement comments and clarifying-answers). Without re-admitting the bot,
  the readiness assessor never sees the implementation context the enhance
  agent posted and re-flags the issue as insufficient on every cycle (#3842).
  Arbitrary bot chatter remains excluded — only comments that contain a Paid
  marker are let through.
- Knowledge search and context-bundle failures degrade gracefully (empty
  context) rather than aborting the assessment.

## Cycle state and calibration

Each `analyze_issue` re-evaluation is a delta against the prior cycle, not a
repeat of the baseline. The prompt threads the issue's `enhance_issue_rounds`,
the project's `max_enhance_issue_reevaluation_rounds`, the prior analyzer
verdict (`last_analyzer_sufficient_context`), the prior `missing_context_areas`,
and a budgeted, section-aware digest of every admissible Paid enhancement and
clarifying-answer marker comment. The verdict and reasoning are persisted back
on the issue (`last_analyzer_*`, `last_analyzed_at`) so operators can see why a
lane stalled and so the next cycle can consume the prior verdict as cycle state.

### Enhancement fidelity (#3850)

Multi-round histories are the norm on looping issues: the latest marker comment
is often just the newest clarifying questions, while the implementation context
from earlier rounds (and any human answers, which arrive as separate comments)
carries the evidence of readiness. Enhancement comments also lead with prose or
`## Clarifying questions` and put `## Implementation context` further down, so
a blind head-truncate of the body cuts exactly the content that matters.

`IssueEnhancements::CommentDigest` therefore shapes marker comments for the
prompt by section, not by byte offset:

- Every comment is split on `##` headings (fenced code blocks are opaque), with
  any prose before the first heading kept as a preamble section.
- Sections are ranked: decision-relevant headings (`Implementation context`,
  `Suggested approach`, `Clarifying questions`, `Clarifying question answers`,
  `Current context`) first, unrecognised prose next, and boilerplate last
  (`<!-- paid:* -->` markers are stripped; `Proposed Change Intent Record`,
  `Auto-enhancement stopped`, `Latest context` are dropped first).
- A single total budget is allocated across all comments in rank order, newer
  comments first within a rank, with a per-section cap so one long section
  cannot starve the others; leftover budget tops up capped sections. The
  retained sections are rendered back in chronological comment order and
  original section order so the narrative still reads top-to-bottom.

The cycle-state section applies this digest to *all* admissible marker
comments under `CYCLE_STATE_BUDGET`; the `## Conversation` section applies it
per comment and additionally bounds the whole section by `CONVERSATION_BUDGET`,
keeping the newest comments and noting how many older ones were omitted.

The cycle-state summary reuses `ClarifyingQuestions::CommentAdmission.paid_marker_comment?`
so the marker text alone is not treated as a trust signal — only comments
authored by the project's GitHub App bot (whose login is unspoofable) are
included. Without this guard, any GitHub user could type `<!-- paid:enhance-issue -->`
followed by arbitrary instructions and steer the verdict by reaching thousands
of chars of untrusted content into the analyzer prompt under `## Cycle state`
(#3842).

The readiness prompt is calibrated so the verdict does not default to
`sufficient_context: false`:

- Codebase-determinable ambiguity is not a blocker. The `create_pr` agent
  reads the repository and self-answers questions that are resolvable from
  the code (existing models, platform targets, patterns, etc.). Only
  ambiguity that changes *product/scope/intent* should gate.
- When prior enhancement rounds produced implementation context and no fresh
  human signal has arrived since, another clarify round has near-zero
  marginal value — default to `sufficient_context: true` so the issue moves
  forward instead of looping.
- When the enhancement round cap has been reached, a new clarification round
  is blocked regardless. The verdict defaults to `sufficient_context: true`
  so the issue can move to `create_pr` instead of being parked in
  `manual_review` forever.

## Response contract

The LLM returns JSON: `sufficient_context` (bool), `reasoning` (string),
`missing_context_areas` (array). Malformed or incomplete JSON is a non-retryable
`AnalyzeIssueInvalidJson` error; the harness is trusted to deliver clean
`response.output`, not Paid.

## Body integrity detection

Investigating the stuck-loop symptom on `viamin/yupyup#3` (#3842, Paid issue
4529) found the root cause was a truncated GitHub issue body cut off
mid-sentence — likely a failed rewrite that replaced the original body with a
partial draft. Neither the analyzer nor the enhancer had any way to detect
this: the assessor judged the fragment as if it were the whole spec, and
`sufficient_context` was depressed for reasons the operator could not see
without opening the issue on GitHub.

`Issues::DetectTruncatedBody` is a cheap structural heuristic — not an LLM
judgment — for whether a body looks cut off: it ends without terminal
punctuation, ends inside an unterminated code fence, or ends with a dangling
heading and no content beneath it. It deliberately tolerates the normal
"unpunctuated" endings a well-formed body can have (a list item, a terminated
code block, or a bare link as the last line) to keep the false-positive rate
low, and skips short bodies (`MIN_LENGTH`) where "no terminal punctuation"
carries no signal.

Detection is computed in code (ZFC: a structural fact), not delegated to the
LLM. `AnalyzeIssueActivity#prompt_for` includes a `## Body integrity warning`
section when detected, telling the assessor as ground truth that the body is
broken and to name it rather than guess at the missing intent. That guidance
alone is not sufficient — an LLM can omit it — so `apply_body_integrity_flag`
deterministically appends the canonical
`"issue body appears truncated — the original intent may be lost"` string to
`missing_context_areas` after parsing, whenever detection fires and the
LLM's own response doesn't already mention truncation/corruption. This
guarantees the flag survives into `last_analyzer_missing_context_areas`
regardless of LLM compliance (`ISSUE-ANALYSIS-016`).

The same detector backs the enhancer: `RunAgentActivity` includes the same
warning in the containerized `enhance_issue` agent's prompt, and
`EnhanceIssueActivity` deterministically prepends a body-integrity notice to
the posted enhancement comment when detected, so a human sees the root cause
without relying on the agent to mention it (`ISSUE-ENHANCEMENT-017`, see
`docs/intent/issue-enhancement/`).

This is detection and surfacing only — auto-repairing a truncated body (e.g.
reconstructing it from git history when it was agent-rewritten) is out of
scope; the flag exists to route the issue to a human who can fix the body
directly.
