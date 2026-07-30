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

1. **Configured preference.** `Knowledge::ProviderSelector.for_chat` reads the
   owner's `kb_chat_runner` + `kb_chat_fallback_runners`, filtered by circuit
   breaker / rate-limit availability (`RunnerState#unavailable?`).
2. **Broadening.** When the preference yields no candidates (the configured
   runner is unavailable), `Knowledge::ProviderSelector.available_chat_runner_keys`
   widens to every chat-enabled `Runner` the owner actually has, applying the
   same availability filter. This is what lets an analysis succeed on `codex`
   when `claude` is rate-limited.
3. **Platform default, availability-gated.** Only when nothing above produces a
   candidate does the activity fall back to `DEFAULT_PROVIDER` ("claude") — and
   only if that default is not itself currently unavailable for the owner.

The previous design forced `[DEFAULT_PROVIDER]` whenever the preference list was
empty, which re-selected the exact provider the availability filter had just
excluded and guaranteed the call targeted a known-unhealthy runner. That is the
run-17220 failure mode this segment now guards against (see
`ISSUE-ANALYSIS-002`).

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
