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
   explicit issue-analysis runner is set.

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
