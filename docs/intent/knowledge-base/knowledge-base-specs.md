# EARS Specs: Knowledge Base

> Testable claims for shipped knowledge collection, retrieval, redaction, and
> evolution behavior. Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r KNOWLEDGE-001`).

- [x] **KNOWLEDGE-001** — When Paid collects project knowledge for a commit, the
  system SHALL persist versioned collector output in PostgreSQL as project
  versions, collector runs, artifacts, chunks, and links, and SHALL stale older
  active artifacts after a full successful collection run for a newer commit.
  *Code:* `app/services/knowledge/collector_runner.rb`,
  `app/services/knowledge/artifact_store.rb`.
  *Test:* `spec/services/knowledge/collector_runner_spec.rb`.

- [x] **KNOWLEDGE-002** — When active chunks need embeddings, the system SHALL
  redact them before embedding, SHALL skip fully redacted chunks, and SHALL
  sync derived vectors into Qdrant without storing chunk content in the Qdrant
  payload.
  *Code:* `app/services/knowledge/embeddings/pipeline.rb`,
  `app/services/knowledge/qdrant/point_sync.rb`.
  *Test:* `spec/services/knowledge/embeddings/pipeline_spec.rb`.

- [x] **KNOWLEDGE-003** — When a project performs knowledge search, the system
  SHALL support exact retrieval through PostgreSQL identifier/trigram matching,
  semantic retrieval through PostgreSQL lexical search plus Qdrant vector
  search when available, and hybrid retrieval that merges and reranks both
  result sets.
  *Code:* `app/services/knowledge/search.rb`,
  `app/services/knowledge/search/exact.rb`,
  `app/services/knowledge/search/semantic.rb`,
  `app/services/knowledge/search/hybrid.rb`,
  `app/services/knowledge/search/reranker.rb`.
  *Test:* `spec/services/knowledge/search_spec.rb`.

- [x] **KNOWLEDGE-004** — When Paid builds a knowledge context bundle for a
  prompt, the system SHALL assemble prioritized knowledge sections within a
  token budget from active project knowledge and durable decision artifacts.
  *Code:* `app/services/knowledge/context_bundle/build.rb`.
  *Test:* `spec/services/knowledge/context_bundle/build_spec.rb`.

- [x] **KNOWLEDGE-005** — When knowledge search or context-bundle assembly is
  performed with an `agent_run_id`, the system SHALL attribute consumed
  knowledge by artifact type and context channel to that run so later analysis
  can aggregate usage and effectiveness.
  *Code:* `app/services/knowledge/search.rb`,
  `app/services/knowledge/context_bundle/build.rb`,
  `app/services/prompts/build_for_issue.rb`,
  `app/temporal/activities/analyze_issue_activity.rb`,
  `app/temporal/activities/enhance_issue_activity.rb`,
  `app/services/knowledge/usage_stats.rb`.
  *Test:* `spec/services/knowledge/search_spec.rb`,
  `spec/services/knowledge/context_bundle/build_spec.rb`,
  `spec/services/knowledge/usage_stats_spec.rb`,
  `spec/temporal/activities/analyze_issue_activity_spec.rb`.

- [x] **KNOWLEDGE-006** — When operators retroactively scrub already-indexed
  knowledge, the system SHALL update PostgreSQL chunk content and status, SHALL
  delete affected Qdrant points, and SHALL record audit events for the scrub.
  *Code:* `app/services/knowledge/redaction/scrubber.rb`.
  *Test:* `spec/services/knowledge/redaction/scrubber_spec.rb`.

- [x] **KNOWLEDGE-007** — When active chunks were partially redacted after they
  were previously embedded, the system SHALL support re-embedding the scrubbed
  content into Qdrant and SHALL record the re-embedded audit trail.
  *Code:* `app/services/knowledge/redaction/reembed.rb`.
  *Test:* `spec/services/knowledge/redaction/reembed_spec.rb`.

- [x] **KNOWLEDGE-008** — When knowledge evolution is enabled for a project,
  the system SHALL sample enhance-issue outcomes and usage data, analyze
  knowledge gaps, and persist pending recommendation records while dismissing
  stale pending recommendations that are no longer flagged.
  *Code:* `app/jobs/knowledge_evolution_job.rb`,
  `app/temporal/workflows/knowledge_evolution_workflow.rb`,
  `app/temporal/activities/record_knowledge_recommendations_activity.rb`.
  *Test:* `spec/temporal/workflows/knowledge_evolution_workflow_spec.rb`,
  `spec/temporal/activities/record_knowledge_recommendations_activity_spec.rb`.
