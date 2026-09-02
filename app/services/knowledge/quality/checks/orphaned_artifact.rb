# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Flags active artifacts with no usable chunk content. An artifact is
    # "orphaned" when it cannot participate in retrieval — either it has
    # zero chunks or every chunk has status `deleted`. Severity: warning.
    class Checks::OrphanedArtifact < Checks::Base
      code "orphaned_artifact"
      severity "warning"

      def collect_findings(collector)
        zero_chunk_findings(collector)
        all_deleted_chunk_findings(collector)
      end

      private

      def zero_chunk_findings(collector)
        scope = KnowledgeArtifact
          .active
          .for_project(project)
          .where.missing(:knowledge_chunks)

        collect_scope(collector, scope) do |artifact|
          build_finding(
            target_type: "KnowledgeArtifact",
            target_id: artifact.id,
            artifact_type: artifact.artifact_type,
            detail: "active artifact has no chunks"
          )
        end
      end

      def all_deleted_chunk_findings(collector)
        scope = KnowledgeArtifact
          .active
          .for_project(project)
          .joins(:knowledge_chunks)
          .group("knowledge_artifacts.id")
          .having(
            "COUNT(*) = SUM(CASE WHEN knowledge_chunks.status = 'deleted' THEN 1 ELSE 0 END)"
          )

        collect_scope(collector, scope, grouped: true) do |artifact|
          build_finding(
            target_type: "KnowledgeArtifact",
            target_id: artifact.id,
            artifact_type: artifact.artifact_type,
            detail: "all chunks have status deleted"
          )
        end
      end
    end
  end
end
