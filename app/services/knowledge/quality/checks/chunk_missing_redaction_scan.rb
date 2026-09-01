# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Flags active chunks that have never been scanned by the redaction
    # pipeline. New chunks are scanned before embedding, but a missed scan
    # means sensitive content might be indexed. Severity is informational;
    # the embedding pipeline guarantees a scan before embedding for normal
    # flows, so this acts as a smoke detector for broken pipelines.
    class Checks::ChunkMissingRedactionScan < Checks::Base
      code "chunk_missing_redaction_scan"
      severity "info"

      def findings
        results = []
        KnowledgeChunk
          .active
          .for_project(project)
          .where(redaction_scanned_at: nil)
          .find_each(batch_size: 200) do |chunk|
            results << build_finding(
              target_type: "KnowledgeChunk",
              target_id: chunk.id,
              artifact_type: chunk.knowledge_artifact&.artifact_type,
              detail: "active chunk has not been scanned for sensitive content"
            )
          end

        results
      end
    end
  end
end
