# EARS Specs: Agent-Run Session Summaries

> Testable claims for capturing, indexing, retrieving, and promoting
> agent-run session summaries. Status markers: `[x]` implemented · `[ ]`
> active gap · `[D]` deferred. Each ID is a grep target across specs, tests,
> and code (`grep -r SESSION-SUMMARY-001`).

- [x] **SESSION-SUMMARY-001** — When a selected agent run (completed,
  non-synthetic, and produced a pull request) finishes, the system SHALL
  enqueue background capture of a session-summary observation linked to that
  agent run, without blocking the run's completion on LLM latency.
  *Code:* `app/temporal/activities/base_activity.rb`,
  `app/temporal/activities/create_pull_request_activity.rb`,
  `app/temporal/activities/complete_existing_pr_run_activity.rb`,
  `app/jobs/capture_agent_run_session_summary_job.rb`.
  *Test:* `spec/temporal/activities/create_pull_request_activity_spec.rb`,
  `spec/temporal/activities/complete_existing_pr_run_activity_spec.rb`,
  `spec/jobs/capture_agent_run_session_summary_job_spec.rb`.

- [x] **SESSION-SUMMARY-002** — When session-summary capture runs for an
  agent run with a non-blank transcript, the system SHALL synthesize a
  structured summary (narrative summary, files touched, decisions,
  assumptions, failures, follow-ups, learnings) via agent-harness and SHALL
  produce nothing when the transcript is blank, the provider call fails, or
  the response cannot be parsed as the expected JSON shape.
  *Code:* `app/services/llm/generate_session_summary.rb`.
  *Test:* `spec/services/llm/generate_session_summary_spec.rb`.

- [x] **SESSION-SUMMARY-003** — When a session summary is captured, the
  system SHALL persist it as an `AgentRunSessionSummary` linked to its
  originating agent run (one per run) and SHALL index it into the
  knowledge-artifact pipeline as a distinct `session_summary` artifact type
  so it becomes searchable.
  *Code:* `app/models/agent_run_session_summary.rb`,
  `app/services/knowledge/session_summaries/capture.rb`,
  `app/services/knowledge/session_summaries/sync_knowledge_artifact.rb`,
  `app/services/knowledge/collectors/session_summary_collector.rb`.
  *Test:* `spec/models/agent_run_session_summary_spec.rb`,
  `spec/services/knowledge/session_summaries/capture_spec.rb`,
  `spec/services/knowledge/session_summaries/sync_knowledge_artifact_spec.rb`,
  `spec/services/knowledge/collectors/session_summary_collector_spec.rb`.

- [x] **SESSION-SUMMARY-004** — When a human promotes a session-summary
  observation, the system SHALL create a draft Change Intent Record seeded
  from the summary's fields, SHALL mark the summary `promoted` with a link
  to the created record and the promoting user, and SHALL reject promoting
  an already-promoted summary. The UI SHALL label an unpromoted summary as
  an observation and a promoted summary with a link to its Change Intent
  Record when that draft still exists; if the promoted draft is later
  discarded, the UI SHALL still render the promoted state without raising
  and SHALL make clear that the draft was discarded, so neither state is
  mistaken for accepted project intent.
  *Code:* `app/services/knowledge/session_summaries/promote.rb`,
  `app/controllers/projects/agent_runs_controller.rb`,
  `app/views/projects/agent_runs/_session_summary.html.erb`.
  *Test:* `spec/services/knowledge/session_summaries/promote_spec.rb`,
  `spec/requests/projects/agent_run_session_summaries_spec.rb`,
  `spec/models/agent_run_session_summary_spec.rb`.

- [x] **SESSION-SUMMARY-005** — When a knowledge context bundle is assembled,
  the system SHALL exclude session summaries by default and SHALL include
  them, under an explicitly labeled "not vetted intent" section at the end of
  the section priority order, only when a caller opts in with
  `include_session_summaries: true`.
  *Code:* `app/services/knowledge/context_bundle/build.rb`.
  *Test:* `spec/services/knowledge/context_bundle/build_spec.rb`.
