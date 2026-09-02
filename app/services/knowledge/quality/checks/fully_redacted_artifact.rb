# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Flags active artifacts whose chunks are all `redacted`. They show up
    # in counts and identifier searches but contribute nothing to retrieval.
    # Operators should treat them as candidates for re-collection (e.g. a
    # newer commit might expose the underlying content) or for explicit
    # archival if the data is permanently sensitive.
    class Checks::FullyRedactedArtifact < Checks::Base
      code "fully_redacted_artifact"
      severity "warning"

      def collect_findings(collector)
        scope = KnowledgeArtifact
          .active
          .for_project(project)
          .joins(:knowledge_chunks)
          .group("knowledge_artifacts.id")
          .having(
            "COUNT(*) = SUM(CASE WHEN knowledge_chunks.status = 'redacted' THEN 1 ELSE 0 END)"
          )

        collect_scope(collector, scope, grouped: true) do |artifact|
          build_finding(
            target_type: "KnowledgeArtifact",
            target_id: artifact.id,
            artifact_type: artifact.artifact_type,
            detail: "all chunks have status redacted"
          )
        end
      end
    end
  end
end
