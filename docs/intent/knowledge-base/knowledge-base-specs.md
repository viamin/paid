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

- [x] **KNOWLEDGE-OKF-001** — When Paid collects knowledge for a repository
  that contains no OKF bundle, the OKF collector SHALL skip without producing
  artifacts and SHALL leave other collectors and the overall collection status
  unaffected.
  *Code:* `app/services/knowledge/collectors/okf_collector.rb`,
  `config/initializers/knowledge_collectors.rb`.
  *Test:* `spec/services/knowledge/collectors/okf_collector_spec.rb`.

- [x] **KNOWLEDGE-OKF-002** — When a repository contains an OKF bundle at a
  conventional `.okf/` root or an explicitly configured path, the OKF collector
  SHALL index each valid Markdown concept file with YAML frontmatter as a
  searchable curated artifact of the distinct `okf_concept` type whose metadata
  carries source path, concept type, title, tags, and last-commit metadata, and
  SHALL preserve the Markdown body as the artifact content and as curated
  definition chunks.
  *Code:* `app/services/knowledge/collectors/okf_collector.rb`.
  *Test:* `spec/services/knowledge/collectors/okf_collector_spec.rb`.

- [x] **KNOWLEDGE-OKF-003** — When a knowledge context bundle is assembled for
  a project with active `okf_concept` artifacts, the system SHALL include that
  curated knowledge under an explicit OKF section within the token budget.
  *Code:* `app/services/knowledge/context_bundle/build.rb`.
  *Test:* `spec/services/knowledge/context_bundle/build_spec.rb`.

- [x] **KNOWLEDGE-OKF-004** — When an OKF bundle file is invalid (missing or
  malformed frontmatter, non-mapping frontmatter, empty body, or oversized
  file), the OKF collector SHALL record a finding in the collector run
  metadata, SHALL complete the run, and SHALL still index the valid files in
  the same bundle.
  *Code:* `app/services/knowledge/collectors/okf_collector.rb`.
  *Test:* `spec/services/knowledge/collectors/okf_collector_spec.rb`.

- [x] **KNOWLEDGE-OKF-005** — When a project member exports selected active
  knowledge artifacts as an OKF bundle, the system SHALL render each selected
  artifact as Markdown with YAML frontmatter carrying its artifact type,
  collector type, scope, identifier, source commit SHA, timestamps, and a
  Paid knowledge-base URI; SHALL exclude artifacts with no active
  (non-redacted, non-stale) chunk content; SHALL let the caller choose
  curated-only or additional derived artifact types; and SHALL package the
  result as a downloadable archive whose files round-trip through the same
  frontmatter parser the OKF collector uses to ingest bundles. The export is
  opt-in and does not alter project knowledge state or imply OKF adoption.
  *Code:* `app/services/knowledge/okf/export.rb`,
  `app/services/knowledge/okf/frontmatter.rb`,
  `app/services/knowledge/okf/bundle_archive.rb`,
  `app/controllers/projects/okf_exports_controller.rb`.
  *Test:* `spec/services/knowledge/okf/export_spec.rb`,
  `spec/services/knowledge/okf/frontmatter_spec.rb`,
  `spec/services/knowledge/okf/bundle_archive_spec.rb`,
  `spec/requests/projects/okf_exports_spec.rb`.

- [x] **KNOWLEDGE-EMBED-001** — When a user configures a knowledge base, the
  system SHALL let them pick any embedding model id served by the configured
  embedding runner together with the dimensions the model emits, validate
  the model id (non-blank, bounded length) and dimensions (positive integer
  bounded by a sensible ceiling), and SHALL use those values when the
  embedding pipeline generates or re-embeds chunks. Defaults preserve the
  legacy `text-embedding-3-large` / 3072 pair so existing knowledge bases
  continue to work without a re-embed. The runner-selection log line that
  warns about embedding fallback SHALL reference the configured model and
  dimensions rather than a hardcoded constant.
  *Code:* `app/models/user_setting.rb`,
  `app/services/knowledge/embeddings/generate.rb`,
  `app/services/knowledge/embeddings/proxy_generator.rb`,
  `app/services/knowledge/runner_selector.rb`,
  `app/services/knowledge/provider_selector.rb`,
  `app/controllers/user_settings_controller.rb`,
  `app/views/user_settings/edit.html.erb`,
  `db/migrate/20260808071316_add_kb_embedding_model_to_user_settings.rb`.
  *Test:* `spec/models/user_setting_spec.rb`,
  `spec/services/knowledge/embeddings/generate_spec.rb`,
  `spec/services/knowledge/embeddings/proxy_generator_spec.rb`,
  `spec/services/knowledge/runner_selector_spec.rb`,
  `spec/services/knowledge/provider_selector_spec.rb`.
