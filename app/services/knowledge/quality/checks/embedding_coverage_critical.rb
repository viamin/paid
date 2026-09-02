# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Escalates chunk_missing_embedding into a single project-level finding
    # when embedding coverage across active chunks is at or near zero. A
    # trickle of missing embeddings is expected while the backfill pipeline
    # catches up; a project where almost nothing is embedded means semantic
    # retrieval has structurally stopped contributing to search, not that
    # it's merely behind — that deserves an error, not thousands of
    # identical per-chunk warnings.
    # @spec KNOWLEDGE-LINT-002
    class Checks::EmbeddingCoverageCritical < Checks::Base
      code "embedding_coverage_critical"
      severity "error"

      MIN_ACTIVE_CHUNKS = 20
      NEAR_ZERO_THRESHOLD = 0.01

      def collect_findings(collector)
        active_scope = KnowledgeChunk.active.for_project(project)
        active_count = active_scope.count
        return if active_count < MIN_ACTIVE_CHUNKS

        embedded_count = active_scope.where.not(embedding_model: nil).count
        coverage = embedded_count.to_f / active_count
        return if coverage > NEAR_ZERO_THRESHOLD

        add_finding(
          collector,
          target_type: "Project",
          target_id: project.id,
          detail: "embedding coverage is #{format('%.2f', coverage * 100)}% " \
            "(#{embedded_count}/#{active_count} active chunks) — semantic search is running lexical-only",
          extra: { active_chunk_count: active_count, embedded_chunk_count: embedded_count }
        )
      end
    end
  end
end
