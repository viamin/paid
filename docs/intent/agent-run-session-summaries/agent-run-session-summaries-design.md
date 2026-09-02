---
parent: PAID
prefix: SESSION-SUMMARY
---

# Low-Level Design: Agent-Run Session Summaries

> Companion to the high-level design (`docs/high-level-design.md`) and the
> [Knowledge Base](../knowledge-base/knowledge-base-design.md) segment. Covers
> capturing structured session summaries from completed agent runs as
> knowledge artifacts, distinct from durable project intent.

## Purpose

Agent runs produce useful learning material beyond the code diff itself:
files touched, decisions reached, assumptions made, approaches that failed,
follow-up work identified, and reusable insights about the repository. AKB's
session-capture plugins showed this material is worth keeping. Paid already
has agent runs, a knowledge-artifact pipeline, and per-run knowledge-usage
attribution — this segment wires the first two together for observation
capture.

Session summaries are explicitly **not** durable project intent. They are
raw, unvetted observations from a single run. A human can promote one into a
draft Change Intent Record, which then goes through the existing Change
Intent draft/approve lifecycle before it counts as accepted knowledge.

## Shipped Behavior

### Capture

`Knowledge::SessionSummaries::Capture` orchestrates capture for a completed
agent run:

1. `Llm::GenerateSessionSummary` synthesizes a structured JSON summary
   (`summary`, `files_touched`, `decisions`, `assumptions`, `failures`,
   `follow_ups`, `learnings`) from the run's transcript via agent-harness,
   using the seeded `knowledge.session_summary.draft` prompt with an in-code
   fallback.
2. The parsed result is persisted as an `AgentRunSessionSummary` —
   `status: "observation"` by default, one row per agent run (unique on
   `agent_run_id`).
3. Token usage is tracked against the agent run and an `LlmOutputMetric` is
   recorded for downstream quality analysis, mirroring
   `Knowledge::Decisions::Draft`.
4. `Knowledge::SessionSummaries::SyncKnowledgeArtifact` indexes the summary
   into `knowledge_artifacts` under a distinct `session_summary` artifact
   type, using the same synthetic-project-version pattern as
   `ChangeIntents::SyncKnowledgeArtifact` (one shared synthetic version and
   collector run per project; each summary gets its own `scope_path`).

### Trigger

Capture is enqueued via `CaptureAgentRunSessionSummaryJob` (queue
`:knowledge`) from `BaseActivity#capture_session_summary_if_needed`, called
from `CreatePullRequestActivity` and `CompleteExistingPrRunActivity` after
`agent_run.complete!` succeeds. Selection is intentionally conservative:
only completed, non-synthetic runs that produced a pull request trigger
capture — runs with no code changes have nothing substantive to summarize.
Running the synthesis out-of-band (a background job, not inline in the
Temporal activity) keeps LLM latency off the completion path.

### Retrieval and priority

`Knowledge::ContextBundle::Build` gained a `session_summaries` section,
appended after every other section in `SECTION_ORDER` — conservative
priority, since these are unvetted observations rather than curated or
durable knowledge. The section is excluded by default; callers opt in with
`include_session_summaries: true`. When included, the same token-budget
truncation and per-artifact-type `KnowledgeUsageStat` attribution that every
other section gets applies automatically.

### Promotion boundary

`Knowledge::SessionSummaries::Promote` is the only path from observation to
durable intent: it creates a **draft** `ChangeIntent` seeded from the
summary's fields and marks the `AgentRunSessionSummary` `status: "promoted"`,
linked to the created record and the promoting user. It deliberately reuses
the existing Change Intent draft/approve/discard lifecycle
(`Projects::ChangeIntentsController`) rather than building a second review
surface — the draft still requires human approval before it enters the
knowledge base, exactly like any other Change Intent Record.

The agent-run show page renders the summary with an explicit "Observation"
badge, or "Promoted to Change Intent" linking to the created record once
promoted. If that draft Change Intent is later discarded, the summary
remains promoted but the UI renders a non-link "Promoted draft discarded"
badge instead of raising on a missing record, so the UI never presents an
unreviewed observation as accepted project intent.

## Important Boundaries

- **Not durable intent on capture.** A captured summary is an observation
  (`status: "observation"`) until a human explicitly promotes it, and even
  then it lands as a draft Change Intent that still needs approval.
- **Not every agent run.** Only completed, PR-producing, non-synthetic runs
  are selected for capture.
- **Not inline with completion.** Synthesis runs in a background job so LLM
  latency never delays marking the run complete or returning its result.
