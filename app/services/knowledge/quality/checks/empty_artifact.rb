# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Flags active artifacts whose chunks are all empty after stripping
    # whitespace/redaction markers. Such artifacts are noise: they appear in
    # counts but contribute nothing retrievable.
    class Checks::EmptyArtifact < Checks::Base
      code "empty_artifact"
      severity "warning"

      def collect_findings(collector)
        scope = KnowledgeArtifact
          .active
          .for_project(project)
          .joins(:knowledge_chunks)
          .where.not(knowledge_chunks: { status: "deleted" })
          .group("knowledge_artifacts.id")
          .having(
            "COUNT(*) = SUM(CASE WHEN BTRIM(knowledge_chunks.content) = '' " \
            "OR BTRIM(knowledge_chunks.content) = '[REDACTED:mixed]' " \
            "OR knowledge_chunks.content ~ '^\\[REDACTED(:[^]]+)?\\]?$' " \
            "THEN 1 ELSE 0 END)"
          )

        collect_scope(collector, scope, grouped: true) do |artifact|
          build_finding(
            target_type: "KnowledgeArtifact",
            target_id: artifact.id,
            artifact_type: artifact.artifact_type,
            detail: "all chunks are empty or fully redacted"
          )
        end
      end
    end
  end
end
